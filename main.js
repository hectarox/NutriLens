require('dotenv').config();
const express = require('express');
const multer = require('multer');
const cors = require('cors');
const path = require('path');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const mysql = require('mysql2/promise');
const crypto = require('crypto');
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
  const { message, lang } = req.body || {};
  // Determine locale: explicit body.lang wins, then Accept-Language header, else English
  const acceptLang = (req.get('accept-language') || '').split(',')[0].trim().toLowerCase();
  const locale = (lang && typeof lang === 'string' && lang.trim()) ? lang.trim().toLowerCase() : (acceptLang || 'en');
  const isEnglishLocale = (
    (typeof lang === 'string' && lang.trim().toLowerCase().startsWith('en')) ||
    (typeof acceptLang === 'string' && acceptLang.startsWith('en'))
  );
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
    const model = genAI.getGenerativeModel({
      model: modelName,
      systemInstruction: "You cannot base yourself off typical serving sizes, only visual information and deep picture analysis of weight. You must find the exact weight to the gram. Also remove ~10% of your estimated weight guess. Always choose your minimum guess, if its between like 213-287, always pick the lowest one. Reply in: " + (locale === 'fr' ? 'french' : 'english'),
      safetySettings: safetySettings,
    });
    // Try the same chat path up to 10 times until we get non-empty content
    for (let i = 0; i < 10; i++) {
      const chatSession = model.startChat({ generationConfig, history });
      const result = await chatSession.sendMessage(message || '');
      const resp = result.response;
      let text = '';
      try { text = await resp.text(); } catch (_) { text = ''; }
      if (!text || String(text).trim().length === 0) {
        try {
          const parts = (resp && resp.candidates && resp.candidates[0] && resp.candidates[0].content && resp.candidates[0].content.parts) || [];
          for (const p of parts) {
            if (p && typeof p.text === 'string' && p.text.trim()) { text = p.text; break; }
            if (p && p.functionCall) { text = JSON.stringify(p.functionCall); break; }
          }
        } catch (_) { /* ignore */ }
      }
      // Log raw for each try
      try { console.log(`[AI][${modelName}][try ${i+1}/10] raw: ${text}`); } catch (_) { }
      // Cleanup and parse
      if (text && text.trim().startsWith('```')) {
        text = text.replace(/^```[a-zA-Z]*\s*/,'').replace(/\s*```$/,'').trim();
      }
      let data = null;
      if (text && text.trim()) {
        try { data = JSON.parse(text); } catch (_) { data = null; }
      }
      if ((text && text.trim()) || (data && Object.keys(data).length)) {
        let finalPayload = data ?? text;
  // Only enforce English normalization when caller locale indicates English
  if (isEnglishLocale) {
          try {
            const normalized = await englishNormalizeWithFlash(genAI, finalPayload);
            if (normalized) finalPayload = normalized;
          } catch (_) { /* fallback to original */ }
        }
        await logRequestIp(req);
        return res.json({ ok: true, data: finalPayload });
      }
    }

    console.warn('Model returned no content after 10 tries');
    return res.status(503).json({ ok: false, error: 'Empty response from model after retries.' });
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
// Feature flag: disable password (JWT) auth when PASSWORD_AUTH=false
const PASSWORD_AUTH = (() => {
  const v = String(process.env.PASSWORD_AUTH ?? process.env.password_auth ?? 'true').toLowerCase();
  return !(v === 'false' || v === '0' || v === 'off' || v === 'no');
})();

app.use(express.json());
app.use(express.urlencoded({ extended: true }));
// Serve static assets (icons, etc.) from /static if needed in the future
app.use('/static', express.static(path.join(__dirname, 'assets')));

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

// Post-process: ensure JSON values are English using a single-pass flash call.
// Returns a parsed object on success, or null to fallback to original.
async function englishNormalizeWithFlash(genAI, originalJsonish) {
  try {
    const model = genAI.getGenerativeModel({
      model: 'gemini-2.5-flash',
      systemInstruction: (
        'You are a JSON post-processor. You will receive a nutrition JSON.\n' +
        '- First, verify the language of all human-readable string values.\n' +
        '- If any value is not English, translate ONLY the values into English.\n' +
        '- Preserve the exact JSON structure and keys. Do not rename keys.\n' +
        '- Keep all numbers and units as-is.\n' +
        '- If everything is already English, return the JSON unchanged.\n' +
        '- Respond with JSON only (no markdown, no code fences).'
      ),
      safetySettings,
    });
    const chat = model.startChat({ generationConfig });
    const payload = (typeof originalJsonish === 'string') ? originalJsonish : JSON.stringify(originalJsonish);
    const msg = 'Verify the following JSON is fully English. If not, translate values to English and return the JSON unchanged in structure and keys. Return JSON only.\n\nJSON:\n' + payload;
    const result = await chat.sendMessage(msg);
    const resp = result && result.response;
    let text = '';
    try { text = await resp.text(); } catch (_) { text = ''; }
    if (text && text.trim().startsWith('```')) {
      text = text.replace(/^```[a-zA-Z]*\s*/, '').replace(/\s*```$/, '').trim();
    }
    if (!text || !text.trim()) return null;
    try {
      const data = JSON.parse(text);
      if (data && typeof data === 'object' && Object.keys(data).length > 0) return data;
    } catch (_) { /* parse failed */ }
    return null;
  } catch (e) {
    try { console.warn('englishNormalizeWithFlash failed:', e && e.message ? e.message : e); } catch (_) {}
    return null;
  }
}

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

  // Key-value settings storage for admin-configurable options
  await pool.query(`
    CREATE TABLE IF NOT EXISTS app_settings (
      k VARCHAR(191) NOT NULL PRIMARY KEY,
      v TEXT NULL,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    ) ENGINE=InnoDB;
  `);

  // Logs of successful requests for reporting
  await pool.query(`
    CREATE TABLE IF NOT EXISTS request_logs (
      id BIGINT AUTO_INCREMENT PRIMARY KEY,
      ip VARCHAR(64) NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      INDEX idx_created_at (created_at),
      INDEX idx_ip (ip)
    ) ENGINE=InnoDB;
  `);

  return pool;
}

let dbPoolPromise = bootstrapDb();

// --------------------------
// Helpers: client IP and logging
// --------------------------
function getClientIp(req) {
  const xf = (req.get('x-forwarded-for') || '').split(',')[0].trim();
  const ip = xf || req.ip || (req.socket && req.socket.remoteAddress) || '';
  return String(ip).slice(0, 64);
}

async function logRequestIp(req) {
  try {
    const ip = getClientIp(req);
    if (!ip) return;
    const pool = await dbPoolPromise;
    await pool.query('INSERT INTO request_logs (ip) VALUES (?)', [ip]);
  } catch (e) {
    try { console.warn('request ip log failed', e && e.message ? e.message : e); } catch (_) {}
  }
}

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
      .col{display:flex;gap:16px;align-items:flex-start}
      .col>*{flex:1}
      .help{color:#666;font-size:12px}
      .preview{border:1px solid #eee;border-radius:8px;padding:12px;min-height:120px}
    </style>
    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
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

    <h2>Announcement</h2>
    <p class="help">Configure localized Markdown announcements shown in the app at startup. Users can choose "Hide forever" per-announcement; you can also provide separate messages for English and French.</p>
    <form id="settingsForm">
      <div class="row">
        <input name="discord_url" placeholder="Discord invite URL (optional)" />
        <input name="github_issues_url" placeholder="GitHub issues URL (optional)" />
      </div>
      <div class="col">
        <div>
          <h3>English</h3>
          <textarea name="announcement_md_en" placeholder="English Markdown... Use $discord and $github_issues tokens to insert logos/links" rows="8"></textarea>
          <h4>Preview (EN)</h4>
          <div id="mdPreviewEn" class="preview"></div>
        </div>
        <div>
          <h3>Français</h3>
          <textarea name="announcement_md_fr" placeholder="Markdown français... Utilisez les tokens $discord et $github_issues" rows="8"></textarea>
          <h4>Prévisualisation (FR)</h4>
          <div id="mdPreviewFr" class="preview"></div>
        </div>
      </div>
      <div class="row">
        <button type="submit">Save</button>
        <span id="saveOut"></span>
      </div>
      <div>
        <h3>Tokens</h3>
        <ul>
          <li><code>$discord</code> → Discord logo + link (uses Discord URL)</li>
          <li><code>$github_issues</code> → GitHub logo + link (uses GitHub Issues URL)</li>
        </ul>
      </div>
    </form>

    <h2>API</h2>
    <p>Mobile login: <code>POST /auth/login { username, password }</code></p>
    <p>Set password: <code>POST /auth/set-password (Bearer token) { newPassword }</code></p>
    <p>Announcement: <code>GET /announcement</code> returns <code>{ ok, markdown }</code></p>
  <h2>Reports</h2>
  <p><a href="/admin/ip-report" download>Download IP report (last 24h)</a></p>
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

      // Settings form
      const settingsForm = document.getElementById('settingsForm');
  const mdEnEl = settingsForm.querySelector('textarea[name="announcement_md_en"]');
  const mdFrEl = settingsForm.querySelector('textarea[name="announcement_md_fr"]');
      const dUrlEl = settingsForm.querySelector('input[name="discord_url"]');
      const gUrlEl = settingsForm.querySelector('input[name="github_issues_url"]');
  const prevEnEl = document.getElementById('mdPreviewEn');
  const prevFrEl = document.getElementById('mdPreviewFr');
      const saveOut = document.getElementById('saveOut');

    function tokenize(md) {
        const d = dUrlEl.value || '#';
        const g = gUrlEl.value || '#';
        const discordImg = 'https://img.icons8.com/color/48/discord--v2.png';
        const githubImg = 'https://img.icons8.com/ios-glyphs/48/github.png';
        return (md || '')
      .replace(/\$discord/g, '[![Discord](' + discordImg + ')](' + d + ')')
      .replace(/\$github_issues/g, '[![GitHub](' + githubImg + ')](' + g + ')');
      }

      function renderPreview() {
        try {
          prevEnEl.innerHTML = marked.parse(tokenize(mdEnEl.value || ''));
        } catch (e) { prevEnEl.textContent = 'Preview error'; }
        try {
          prevFrEl.innerHTML = marked.parse(tokenize(mdFrEl.value || ''));
        } catch (e) { prevFrEl.textContent = 'Preview error'; }
      }
      mdEnEl.addEventListener('input', renderPreview);
      mdFrEl.addEventListener('input', renderPreview);
      dUrlEl.addEventListener('input', renderPreview);
      gUrlEl.addEventListener('input', renderPreview);

      async function loadSettings() {
        const res = await fetch('/admin/settings');
        const json = await res.json();
        if (json && json.ok && json.settings) {
          mdEnEl.value = json.settings.announcement_md_en || json.settings.announcement_md || '';
          mdFrEl.value = json.settings.announcement_md_fr || '';
          dUrlEl.value = json.settings.discord_url || '';
          gUrlEl.value = json.settings.github_issues_url || '';
          renderPreview();
        }
      }
      loadSettings();

      settingsForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        saveOut.textContent = 'Saving...';
        const body = {
          announcement_md_en: mdEnEl.value || '',
          announcement_md_fr: mdFrEl.value || '',
          discord_url: dUrlEl.value || '',
          github_issues_url: gUrlEl.value || ''
        };
        const res = await fetch('/admin/settings', { method: 'POST', headers: { 'Content-Type':'application/json' }, body: JSON.stringify(body) });
        const json = await res.json();
        saveOut.textContent = json.ok ? 'Saved' : 'Save failed';
        renderPreview();
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

// Admin: read/save settings
app.get('/admin/settings', requireAdmin, async (req, res) => {
  try {
    const pool = await dbPoolPromise;
    const [rows] = await pool.query('SELECT k, v FROM app_settings');
    const map = {};
    if (Array.isArray(rows)) {
      for (const r of rows) { map[r.k] = r.v; }
    }
    res.json({ ok: true, settings: {
      // Backward compat: announcement_md kept if present; new fields preferred
      announcement_md: map.announcement_md || '',
      announcement_md_en: map.announcement_md_en || map.announcement_md || '',
      announcement_md_fr: map.announcement_md_fr || '',
      discord_url: map.discord_url || '',
      github_issues_url: map.github_issues_url || ''
    }});
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok:false, error:'load settings failed' });
  }
});

app.post('/admin/settings', requireAdmin, async (req, res) => {
  try {
    const { announcement_md_en = '', announcement_md_fr = '', discord_url = '', github_issues_url = '' } = req.body || {};
    const pool = await dbPoolPromise;
    const entries = [
      // Keep legacy key updated to EN for clients that don’t support locale yet
      ['announcement_md', String(announcement_md_en || '')],
      ['announcement_md_en', String(announcement_md_en || '')],
      ['announcement_md_fr', String(announcement_md_fr || '')],
      ['discord_url', String(discord_url || '')],
      ['github_issues_url', String(github_issues_url || '')],
    ];
    for (const [k, v] of entries) {
      await pool.query('INSERT INTO app_settings (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v=VALUES(v)', [k, v]);
    }
    res.json({ ok:true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok:false, error:'save settings failed' });
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
if (PASSWORD_AUTH) {
  app.get('/ping', authJwt, (req, res) => res.json({ ok:true, pong:true }));
  app.post('/ping', authJwt, (req, res) => res.json({ ok:true, pong:true }));
} else {
  app.get('/ping', (req, res) => res.json({ ok:true, pong:true }));
  app.post('/ping', (req, res) => res.json({ ok:true, pong:true }));
}

const upload = multer({ dest: 'uploads/' });
const modelGuards = PASSWORD_AUTH ? [authJwt, requireToken] : [requireToken];
app.post('/data', ...modelGuards, upload.single('image'), async (req, res) => {
  try {
    const { message } = req.body || {};
    if (typeof message === 'string' && message.toLowerCase().includes('ping')) {
      await logRequestIp(req);
      return res.json({ ok: true, data: { echo: message, note: 'fast-path' } });
    }
  } catch (_) {}
  handleRequestWithRetry(req, res);
});

// Admin: downloadable IP report (last 24h)
app.get('/admin/ip-report', requireAdmin, async (req, res) => {
  try {
    const pool = await dbPoolPromise;
    const [rows] = await pool.query(
      'SELECT ip, COUNT(*) AS cnt FROM request_logs WHERE created_at >= (NOW() - INTERVAL 1 DAY) GROUP BY ip ORDER BY cnt DESC'
    );
    const lines = Array.isArray(rows) ? rows.map(r => `${r.ip}\t${r.cnt}`).join('\n') : '';
    const fname = `ip_report_${new Date().toISOString().slice(0,10)}.txt`;
    res.set('Content-Type', 'text/plain; charset=utf-8');
    res.set('Content-Disposition', `attachment; filename="${fname}"`);
    res.send(lines + (lines ? '\n' : ''));
  } catch (e) {
    console.error(e);
    res.status(500).send('report failed');
  }
});

// Public announcement endpoint (no auth) – returns processed Markdown
app.get('/announcement', async (req, res) => {
  try {
    const pool = await dbPoolPromise;
    const [rows] = await pool.query('SELECT k, v FROM app_settings WHERE k IN ("announcement_md","announcement_md_en","announcement_md_fr","discord_url","github_issues_url")');
    const map = {};
    if (Array.isArray(rows)) {
      for (const r of rows) map[r.k] = r.v;
    }
    // Determine locale from query ?lang=fr / ?lang=en or Accept-Language
    const qLang = (req.query.lang || '').toString().trim().toLowerCase();
    const acceptLang = (req.get('accept-language') || '').split(',')[0].trim().toLowerCase();
    const lang = qLang === 'fr' || qLang === 'en' ? qLang : (acceptLang.startsWith('fr') ? 'fr' : 'en');

    const md = String(
      lang === 'fr' ? (map.announcement_md_fr || '') : (map.announcement_md_en || map.announcement_md || '')
    ).trim();
    const discord = String(map.discord_url || '').trim();
    const issues = String(map.github_issues_url || '').trim();
    const discordImg = 'https://img.icons8.com/color/48/discord--v2.png';
    const githubImg = 'https://img.icons8.com/ios-glyphs/48/github.png';
    const processed = md
      .replace(/\$discord/g, `[![Discord](${discordImg})](${discord || '#'})`)
      .replace(/\$github_issues/g, `[![GitHub](${githubImg})](${issues || '#'})`);
  const id = crypto.createHash('sha1').update(processed).digest('hex');
  res.json({ ok: true, id, markdown: processed });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok:false, error:'announcement failed' });
  }
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running at http://0.0.0.0:${PORT}`);
});