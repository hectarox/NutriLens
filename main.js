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
  if (attempt >= apiKeys.length) {
    res.status(500).send('All API keys are invalid');
    return;
  }

  const apiKey = getNextApiKey();
  const genAI = new GoogleGenerativeAI(apiKey);
  const fileManager = new GoogleAIFileManager(apiKey);

  try {
    const { file } = req;
    const { message } = req.body || {};

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

    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-pro",
      systemInstruction: "You cannot base yourself off typical serving sizes, only visual information and deep picture analysis of weight. You must find the exact weight to the gram. Also remove ~10% of your estimated weight guess. Always choose your minimum guess, if its between like 213-287, always pick the lowest one",
      safetySettings: safetySettings,
    });

    const chatSession = model.startChat({
      generationConfig,
      history,
    });

    const result = await chatSession.sendMessage(message || '');
    let text = await result.response.text();

    // Try to parse JSON if the model respected responseMimeType
    let data;
    try {
      data = JSON.parse(text);
    } catch (_) {
      data = null;
    }

    res.json({ ok: true, data: data ?? text });
  } catch (error) {
    console.error(`Error with API key ${apiKey}:`, error);
    handleRequestWithRetry(req, res, attempt + 1);
  }
}

const app = express();
const APP_TOKEN = process.env.APP_TOKEN || 'FromHectaroxWithLove';
const JWT_SECRET = process.env.JWT_SECRET || 'dev_secret';
const PORT = Number(process.env.PORT || 3000);

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
// Admin panel (simple HTML)
// --------------------------
app.get('/', (req, res) => {
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
app.post('/admin/invite', async (req, res) => {
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