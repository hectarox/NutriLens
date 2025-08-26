require('dotenv').config();
const express = require('express');
const multer = require('multer');
const cors = require('cors');
const path = require('path');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const mysql = require('mysql2/promise');
const {
  GoogleGenerativeAI,
  HarmCategory,
  HarmBlockThreshold,
} = require("@google/generative-ai");
const { GoogleAIFileManager } = require("@google/generative-ai/server");
const apiKeys = (process.env.GEMINI_API_KEYS || '')
  .split(',')
  .map(k => k.trim())
  .filter(Boolean);
let currentApiKeyIndex = 0;

function getNextApiKey() {
  const apiKey = apiKeys[currentApiKeyIndex];
  currentApiKeyIndex = (currentApiKeyIndex + 1) % apiKeys.length;
  return apiKey;
}

async function handleRequestWithRetry(req, res, attempt = 0) {
  if (!apiKeys || apiKeys.length === 0) {
    return res.status(503).json({ ok: false, error: 'Service is currently unavailable, please try again later.' });
  }
  if (attempt >= apiKeys.length) {
    return res.status(503).json({ ok: false, error: 'Service is currently unavailable, please try again later.' });
  }

  const apiKey = getNextApiKey();
  const genAI = new GoogleGenerativeAI(apiKey);
  const fileManager = new GoogleAIFileManager(apiKey);

  try {
  const { file } = req;
  const { message } = req.body || {};
  const useFlash = String(req.query.flash || '0') === '1';

    if (!file && (!message || String(message).trim().length === 0)) {
      return res.status(400).json({ ok: false, error: 'No input provided. Please include a message and/or an image.' });
    }

    let fileData = null;
    if (file) {
      const uploadedFile = await uploadToGemini(file.path, file.mimetype, fileManager);
      fileData = {
        mimeType: uploadedFile.mimeType,
        fileUri: uploadedFile.uri,
      };
    }

    const history = [
      {
        role: "user",
        parts: [
          ...(fileData ? [{ fileData }] : []),
          { text: message },
        ],
      },
    ];

    const modelName = useFlash ? "gemini-2.5-flash" : "gemini-2.5-pro";
    const compat = String(req.query.compat || '0') === '1';
    const model = genAI.getGenerativeModel({
      model: modelName,
      systemInstruction: "You cannot base yourself off typical serving sizes, only visual information and deep picture analysis of weight. You must find the exact weight to the gram. Also remove ~10% of your estimated weight guess. Always choose your minimum guess, if its between like 213-287, always pick the lowest one",
      safetySettings: safetySettings,
    });

    // Minimal compatibility path: direct generateContent without response schema/mime
    if (compat) {
      const altCfg = { ...generationConfig };
      delete altCfg.responseMimeType;
      delete altCfg.responseSchema;
      const gcCompat = await model.generateContent({
        contents: [
          { role: 'user', parts: [ ...(fileData ? [{ fileData }] : []), { text: message || '' } ] },
        ],
        generationConfig: altCfg,
      });
      let compatText = '';
      try { compatText = await gcCompat.response.text(); } catch (_) { compatText = ''; }
      console.log(`[AI][${modelName}][compat] raw: ${compatText}`);
      let compatData = null;
      if (compatText && compatText.trim()) {
        // Strip code fences if present
        if (compatText.trim().startsWith('```')) {
          compatText = compatText.replace(/^```[a-zA-Z]*\s*/,'').replace(/\s*```$/,'').trim();
        }
        try { compatData = JSON.parse(compatText); } catch (_) { compatData = null; }
      }
      return res.json({ ok: true, data: compatData ?? compatText });
    }

  const chatSession = model.startChat({
      generationConfig,
      history,
    });

    const result = await chatSession.sendMessage(message || '');
    const resp = result.response;
    let text = '';
    // Primary: try response.text()
    try {
      text = await resp.text();
    } catch (_) {
      text = '';
    }
    // Fallback: inspect candidates/parts for any textual content
    if (!text || String(text).trim().length === 0) {
      try {
        const parts = (resp && resp.candidates && resp.candidates[0] && resp.candidates[0].content && resp.candidates[0].content.parts) || [];
        for (const p of parts) {
          if (p && typeof p.text === 'string' && p.text.trim()) {
            text = p.text;
            break;
          }
          if (p && p.functionCall) {
            // As a last resort, expose functionCall as JSON
            text = JSON.stringify(p.functionCall);
            break;
          }
        }
      } catch (_) { /* ignore */ }
    }
    // Log raw response before any cleanup
    try {
      console.log(`[AI][${modelName}] raw: ${text}`);
    } catch (_) { /* ignore logging errors */ }

    // If text is in Markdown code fences, strip them
    if (text && text.trim().startsWith('```')) {
      // Remove opening ```json or ``` and trailing ```
      text = text.replace(/^```[a-zA-Z]*\s*/,'').replace(/\s*```$/,'').trim();
    }
    // Try to parse JSON when appropriate
    let data;
    if (text && text.trim()) {
      try {
        data = JSON.parse(text);
      } catch (_) {
        data = null;
      }
    }
    // If still no text and no data, attempt a fallback path for pro model
    if ((!text || !text.trim()) && (!data || (typeof data === 'object' && Object.keys(data).length === 0))) {
      if (modelName === 'gemini-2.5-pro') {
        try {
          // Fallback #1: direct generateContent with same config
          const gc = await model.generateContent({
            contents: [
              {
                role: 'user',
                parts: [
                  ...(fileData ? [{ fileData }] : []),
                  { text: message || '' },
                ],
              },
            ],
            generationConfig,
          });
          let gcText = '';
          try { gcText = await gc.response.text(); } catch (_) { gcText = ''; }
          console.log(`[AI][${modelName}] fallback#1 raw: ${gcText}`);
          if (gcText && gcText.trim().startsWith('```')) {
            gcText = gcText.replace(/^```[a-zA-Z]*\s*/,'').replace(/\s*```$/,'').trim();
          }
          let gcData = null;
          if (gcText && gcText.trim()) {
            try { gcData = JSON.parse(gcText); } catch (_) { gcData = null; }
          }
          if ((gcText && gcText.trim()) || (gcData && Object.keys(gcData).length)) {
            return res.json({ ok: true, data: gcData ?? gcText });
          }
        } catch (e) {
          console.warn('[AI] fallback#1 error:', e);
        }

        try {
          // Fallback #2: retry without forcing JSON schema/mime
          const altModel = genAI.getGenerativeModel({
            model: modelName,
            systemInstruction: "You cannot base yourself off typical serving sizes, only visual information and deep picture analysis of weight. You must find the exact weight to the gram. Also remove ~10% of your estimated weight guess. Always choose your minimum guess, if its between like 213-287, always pick the lowest one",
            safetySettings,
          });
          const altCfg = { ...generationConfig };
          delete altCfg.responseMimeType;
          delete altCfg.responseSchema;
          const gc2 = await altModel.generateContent({
            contents: [
              {
                role: 'user',
                parts: [
                  ...(fileData ? [{ fileData }] : []),
                  { text: message || '' },
                ],
              },
            ],
            generationConfig: altCfg,
          });
          let gc2Text = '';
          try { gc2Text = await gc2.response.text(); } catch (_) { gc2Text = ''; }
          console.log(`[AI][${modelName}] fallback#2 raw: ${gc2Text}`);
          let gc2Data = null;
          if (gc2Text && gc2Text.trim()) {
            try { gc2Data = JSON.parse(gc2Text); } catch (_) { gc2Data = null; }
          }
          if ((gc2Text && gc2Text.trim()) || (gc2Data && Object.keys(gc2Data).length)) {
            return res.json({ ok: true, data: gc2Data ?? gc2Text });
          }
        } catch (e) {
          console.warn('[AI] fallback#2 error:', e);
        }
      }
      console.warn('Model returned no content; candidates:', JSON.stringify(resp && resp.candidates ? resp.candidates : undefined));
      return res.status(503).json({ ok: false, error: 'Empty response from model. You can retry or switch to flash.' });
    }

    res.json({ ok: true, data: data ?? text });
  } catch (error) {
    console.error(`Error with API key ${apiKey}:`, error);
    const status = (error && (error.status || (error.response && error.response.status))) || 0;
    // If model is overloaded or internal error, try remaining keys; if exhausted, return friendly message
    if ((status === 503 || status === 500)) {
      if (attempt + 1 < apiKeys.length) {
        return handleRequestWithRetry(req, res, attempt + 1);
      }
      return res.status(503).json({ ok: false, error: 'AI is overloaded. You can retry with a faster, less precise model.' });
    }
    // Other errors: keep rotating keys until exhausted, then return friendly message
    if (attempt + 1 < apiKeys.length) {
      return handleRequestWithRetry(req, res, attempt + 1);
    }
    return res.status(503).json({ ok: false, error: 'Service is currently unavailable, please try again later.' });
  }
}

const app = express();
const APP_TOKEN = process.env.APP_TOKEN || 'FromHectaroxWithLove';
const JWT_SECRET = process.env.JWT_SECRET || 'dev_secret';
const PORT = Number(process.env.PORT || 3000);
const ADMIN_USER = process.env.ADMIN_USER || 'admin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '';

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Simple shared-secret guard; require header or bearer token
function requireToken(req, res, next) {
  const headerToken = req.get('x-app-token');
  const bearer = req.get('authorization');
  const bearerToken = bearer && /^Bearer\s+(.+)/i.test(bearer) ? bearer.replace(/^Bearer\s+/i, '') : undefined;
  const token = headerToken || bearerToken;
  if (token !== APP_TOKEN) {
    return res.status(401).json({ ok: false, error: 'Unauthorized' });
  }
  next();
}
// Allow cross-origin requests from Flutter web/dev servers during development
app.use(cors());
const safetySettings = [
  {
    category: HarmCategory.HARM_CATEGORY_HARASSMENT,
    threshold: HarmBlockThreshold.BLOCK_NONE,
  },
  {
    category: HarmCategory.HARM_CATEGORY_HATE_SPEECH,
    threshold: HarmBlockThreshold.BLOCK_NONE,
  },
];

const generationConfig = {
  temperature: 0,
  topP: 0.95,
  topK: 1,
  maxOutputTokens: 8192,
  responseMimeType: "application/json",
  responseSchema: {
    type: "object",
    properties: {
      "Nom de l'aliment": {
        type: "string"
      },
      "Poids (g)": {
        type: "string"
      },
      Ingredients: {
        type: "string"
      },
      Glucides: {
        type: "string"
      },
      Proteines: {
        type: "string"
      },
      Lipides: {
        type: "string"
      },
      Sauce: {
        type: "string"
      },
      Calories: {
        type: "string"
      },
    },
    required: [
      "Nom de l'aliment",
      "Poids (g)",
      "Calories",
      "Glucides",
      "Proteines",
      "Lipides",
    ]
  },
};

/**
 * Uploads the given file to Gemini.
 *
 * See https://ai.google.dev/gemini-api/docs/prompting_with_media
 */
async function uploadToGemini(path, mimeType, fileManager) {
  const uploadResult = await fileManager.uploadFile(path, {
    mimeType,
    displayName: path,
  });
  const file = uploadResult.file;
  console.log(`Uploaded file ${file.displayName} as: ${file.name}`);
  return file;
}

// (routes moved below after auth & upload are defined)

// --------------------------
// Database bootstrap (MySQL)
// --------------------------
async function bootstrapDb() {
  const { DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME } = process.env;
  const adminConn = await mysql.createConnection({
    host: DB_HOST,
    port: Number(DB_PORT || 3306),
    user: DB_USER,
    password: DB_PASSWORD,
    multipleStatements: true,
  });
  await adminConn.query(`CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;`);
  await adminConn.end();

  const pool = await mysql.createPool({
    host: DB_HOST,
    port: Number(DB_PORT || 3306),
    user: DB_USER,
    password: DB_PASSWORD,
    database: DB_NAME,
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
  });

  // Create tables if not exist
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id INT AUTO_INCREMENT PRIMARY KEY,
      username VARCHAR(191) NOT NULL UNIQUE,
      password_hash VARCHAR(255) NOT NULL,
      force_password_reset TINYINT(1) NOT NULL DEFAULT 1,
      is_admin TINYINT(1) NOT NULL DEFAULT 0,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    ) ENGINE=InnoDB;
  `);

  return pool;
}

let dbPoolPromise = bootstrapDb();

// --------------------------
// Auth helpers
// --------------------------
function signToken(user) {
  return jwt.sign({ sub: user.id, username: user.username, is_admin: !!user.is_admin }, JWT_SECRET, { expiresIn: '7d' });
}

function authJwt(req, res, next) {
  const auth = req.get('authorization') || '';
  const m = auth.match(/^Bearer\s+(.+)/i);
  if (!m) return res.status(401).json({ ok: false, error: 'Missing token' });
  try {
    const payload = jwt.verify(m[1], JWT_SECRET);
    req.user = payload;
    next();
  } catch (e) {
    return res.status(401).json({ ok: false, error: 'Invalid token' });
  }
}

// Existing app token guard retained for extra protection on model endpoints
function requireToken(req, res, next) {
  const headerToken = req.get('x-app-token');
  const bearer = req.get('authorization');
  const bearerToken = bearer && /^Bearer\s+(.+)/i.test(bearer) ? bearer.replace(/^Bearer\s+/i, '') : undefined;
  const token = headerToken || bearerToken;
  if (token !== APP_TOKEN) {
    return res.status(401).json({ ok: false, error: 'Unauthorized' });
  }
  next();
}

// --------------------------
// Basic auth for Admin panel
// --------------------------
function parseBasicAuth(req) {
  const header = req.get('authorization') || '';
  if (!/^Basic\s+/i.test(header)) return null;
  try {
    const b64 = header.replace(/^Basic\s+/i, '');
    const s = Buffer.from(b64, 'base64').toString('utf8');
    const i = s.indexOf(':');
    if (i < 0) return null;
    return { user: s.slice(0, i), pass: s.slice(i + 1) };
  } catch (_) { return null; }
}

function requireAdmin(req, res, next) {
  if (!ADMIN_PASSWORD) {
    return res.status(500).send('Admin password not set on server');
  }
  const creds = parseBasicAuth(req);
  if (!creds || creds.user !== ADMIN_USER || creds.pass !== ADMIN_PASSWORD) {
    res.set('WWW-Authenticate', 'Basic realm="NutriLens Admin"');
    return res.status(401).send('Authentication required');
  }
  next();
}

// --------------------------
// Admin panel (simple HTML)
// --------------------------
app.get('/', requireAdmin, (req, res) => {
  res.send(`<!doctype html>
  <html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>NutriLens Admin</title>
    <style>
      body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:24px;}
      form{margin:12px 0;padding:12px;border:1px solid #eee;border-radius:8px;max-width:520px}
      input,button{padding:8px;margin:4px 0;font-size:14px}
      .row{display:flex;gap:8px}
      .row>*{flex:1}
      code{background:#f6f8fa;padding:2px 6px;border-radius:4px}
    </style>
  </head>
  <body>
    <h1>NutriLens Admin</h1>
    <p>Invite a user: this creates a username with a temporary password. On first login, the user must set a new password.</p>
    <form id="inviteForm">
      <div class="row">
        <input name="username" placeholder="username" required />
      </div>
      <button type="submit">Invite</button>
      <div id="inviteOut"></div>
    </form>

    <h2>API</h2>
    <p>Mobile login: <code>POST /auth/login { username, password }</code></p>
    <p>Set password: <code>POST /auth/set-password (Bearer token) { newPassword }</code></p>
    <script>
      const form = document.getElementById('inviteForm');
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const fd = new FormData(form);
        const username = fd.get('username');
        const res = await fetch('/admin/invite', { method: 'POST', headers: { 'Content-Type':'application/json' }, body: JSON.stringify({ username }) });
        const json = await res.json();
        document.getElementById('inviteOut').textContent = JSON.stringify(json, null, 2);
      });
    </script>
  </body>
  </html>`);
});

// Admin invite (no auth for simplicity; in prod restrict this)
app.post('/admin/invite', requireAdmin, async (req, res) => {
  try {
    const { username } = req.body || {};
    if (!username || String(username).length < 3) return res.status(400).json({ ok:false, error:'username too short' });
    const pool = await dbPoolPromise;
    // Generate temporary password
    const temp = Math.random().toString(36).slice(2, 10);
    const hash = await bcrypt.hash(temp, 10);
    await pool.query('INSERT INTO users (username, password_hash, force_password_reset) VALUES (?, ?, 1) ON DUPLICATE KEY UPDATE force_password_reset=VALUES(force_password_reset), password_hash=VALUES(password_hash)', [username, hash]);
    res.json({ ok:true, username, temporaryPassword: temp });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok:false, error:'invite failed' });
  }
});

// Auth routes
app.post('/auth/login', async (req, res) => {
  try {
    const { username, password } = req.body || {};
    if (!username || !password) return res.status(400).json({ ok:false, error:'missing credentials' });
    const pool = await dbPoolPromise;
    const [rows] = await pool.query('SELECT * FROM users WHERE username=? LIMIT 1', [username]);
    if (!Array.isArray(rows) || rows.length === 0) return res.status(401).json({ ok:false, error:'invalid credentials' });
    const user = rows[0];
    const ok = await bcrypt.compare(password, user.password_hash);
    if (!ok) return res.status(401).json({ ok:false, error:'invalid credentials' });
    const token = signToken(user);
    res.json({ ok:true, token, forcePasswordReset: !!user.force_password_reset });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok:false, error:'login failed' });
  }
});

app.post('/auth/set-password', authJwt, async (req, res) => {
  try {
    const { newPassword } = req.body || {};
    if (!newPassword || String(newPassword).length < 6) return res.status(400).json({ ok:false, error:'password too short' });
    const pool = await dbPoolPromise;
    const hash = await bcrypt.hash(newPassword, 10);
    await pool.query('UPDATE users SET password_hash=?, force_password_reset=0 WHERE id=?', [hash, req.user.sub]);
    res.json({ ok:true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok:false, error:'set-password failed' });
  }
});

// Existing endpoints: protect with both JWT (user logged-in) and app token for model calls
app.get('/ping', authJwt, (req, res) => res.json({ ok:true, pong:true }));
app.post('/ping', authJwt, (req, res) => res.json({ ok:true, pong:true }));

const upload = multer({ dest: 'uploads/' });
app.post('/data', authJwt, requireToken, upload.single('image'), async (req, res) => {
  try {
    const { message } = req.body || {};
    if (typeof message === 'string' && message.toLowerCase().includes('ping')) {
      return res.json({ ok: true, data: { echo: message, note: 'fast-path' } });
    }
  } catch (_) {}
  handleRequestWithRetry(req, res);
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running at http://0.0.0.0:${PORT}`);
});