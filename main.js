import dotenv from 'dotenv';
import express from 'express';
import multer from 'multer';
import cors from 'cors';
import path from 'path';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';
import mysql from 'mysql2/promise';
import crypto from 'crypto';
import { GoogleGenAI, Type } from '@google/genai';
import { fileURLToPath } from 'url';
import { promises as fs } from 'fs';

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const uploadDir = path.resolve(process.cwd(), 'uploads');

fs.mkdir(uploadDir, { recursive: true }).catch(() => { });

const apiKeys = (process.env.GEMINI_API_KEYS || '')
  .split(',')
  .map((k) => k.trim())
  .filter(Boolean);

const specialKey = process.env.SPECIAL_KEY ? process.env.SPECIAL_KEY.trim() : null;

const useVertexArg = process.argv.includes('--vertex');
const vertexApiKey = process.env.VERTEX_API_KEY;

let currentApiKeyIndex = 0;

function getNextApiKey() {
  const apiKey = apiKeys[currentApiKeyIndex];
  currentApiKeyIndex = (currentApiKeyIndex + 1) % apiKeys.length;
  return apiKey;
}

const safetySettings = [
  { category: 'HARM_CATEGORY_HARASSMENT', threshold: 'BLOCK_NONE' },
  { category: 'HARM_CATEGORY_HATE_SPEECH', threshold: 'BLOCK_NONE' },
];

const nutritionResponseSchema = {
  type: Type.OBJECT,
  properties: {
    "Nom de l'aliment": { type: Type.STRING },
    'Poids (g)': { type: Type.STRING },
    Ingredients: { type: Type.STRING },
    Glucides: { type: Type.STRING },
    Proteines: { type: Type.STRING },
    Lipides: { type: Type.STRING },
    Sauce: { type: Type.STRING },
    Calories: { type: Type.STRING },
  },
  required: [
    "Nom de l'aliment",
    'Poids (g)',
    'Calories',
    'Glucides',
    'Proteines',
    'Lipides',
  ],
};

const chatResponseSchema = {
  type: Type.ARRAY,
  items: {
    // Discriminated union by `type` to reduce hallucinated/irrelevant fields.
    anyOf: [
      {
        type: Type.OBJECT,
        properties: {
          type: { type: Type.STRING, enum: ['message'] },
          content: { type: Type.STRING },
        },
        required: ['type', 'content'],
        additionalProperties: false,
      },
      {
        type: Type.OBJECT,
        properties: {
          type: { type: Type.STRING, enum: ['quickReplies'] },
          quickReplies: { type: Type.ARRAY, items: { type: Type.STRING } },
        },
        required: ['type', 'quickReplies'],
        additionalProperties: false,
      },
      {
        type: Type.OBJECT,
        properties: {
          type: { type: Type.STRING, enum: ['tip'] },
          title: { type: Type.STRING },
          description: { type: Type.STRING },
        },
        required: ['type', 'title', 'description'],
        additionalProperties: false,
      },
      {
        type: Type.OBJECT,
        properties: {
          type: { type: Type.STRING, enum: ['recipe'] },
          title: { type: Type.STRING },
          ingredients: { type: Type.ARRAY, items: { type: Type.STRING } },
          instructions: { type: Type.ARRAY, items: { type: Type.STRING } },
          calories: { type: Type.STRING },
          carbs: { type: Type.STRING },
          protein: { type: Type.STRING },
          fat: { type: Type.STRING },
          weight: { type: Type.STRING },
          sourceUrl: { type: Type.STRING },
        },
        required: ['type', 'title', 'ingredients', 'instructions', 'calories'],
        additionalProperties: false,
      },
    ],
  },
};

const generationDefaults = {
  temperature: 0,
  topP: 0.95,
  topK: 1,
  maxOutputTokens: 8192,
};

const normalizationInstruction = [
  'You are a JSON post-processor. You will receive a nutrition JSON.',
  '- First, verify the language of all human-readable string values.',
  '- If any value is not English, translate ONLY the values into English.',
  '- Preserve the exact JSON structure and keys. Do not rename keys.',
  '- Keep all numbers and units as-is.',
  '- If everything is already English, return the JSON unchanged.',
  '- Respond with JSON only (no markdown, no code fences).',
].join('\n');

async function buildInlineImagePart(uploadedFile) {
  if (!uploadedFile) {
    return null;
  }

  if (uploadedFile.buffer && uploadedFile.buffer.length > 0) {
    return {
      inlineData: {
        data: uploadedFile.buffer.toString('base64'),
        mimeType: uploadedFile.mimetype || 'application/octet-stream',
      },
    };
  }

  const candidates = [];
  if (uploadedFile.path) {
    candidates.push(uploadedFile.path);
  }
  if (uploadedFile.destination && uploadedFile.filename) {
    candidates.push(path.join(uploadedFile.destination, uploadedFile.filename));
  }
  if (uploadedFile.filename) {
    candidates.push(path.join(uploadDir, uploadedFile.filename));
  }

  let absolutePath = null;
  for (const candidate of candidates) {
    if (!candidate) continue;
    const resolved = path.isAbsolute(candidate) ? candidate : path.resolve(process.cwd(), candidate);
    try {
      await fs.access(resolved);
      absolutePath = resolved;
      break;
    } catch (_) {
      // try next candidate
    }
  }

  if (absolutePath) {
    try {
      const buffer = await fs.readFile(absolutePath);
      try {
        await fs.unlink(absolutePath);
      } catch (_) { }
      return {
        inlineData: {
          data: buffer.toString('base64'),
          mimeType: uploadedFile.mimetype || 'application/octet-stream',
        },
      };
    } catch (readError) {
      try {
        console.warn('Failed to read uploaded image file:', readError?.message ?? readError);
      } catch (_) { }
    }
  }

  try {
    console.warn('Uploaded image file not found on disk for inline upload.');
  } catch (_) { }
  return null;
}

function extractResponseText(response) {
  if (!response) return '';
  if (typeof response.text === 'string') return response.text;
  if (typeof response.outputText === 'string') return response.outputText;
  if (typeof response.output_text === 'string') return response.output_text;
  if (Array.isArray(response.functionCalls) && response.functionCalls.length > 0) {
    try {
      return JSON.stringify(response.functionCalls[0]);
    } catch (_) {
      return '';
    }
  }
  const candidateParts = response?.candidates?.[0]?.content?.parts;
  if (Array.isArray(candidateParts)) {
    for (const part of candidateParts) {
      if (part?.jsonValue && typeof part.jsonValue === 'object') {
        try {
          return JSON.stringify(part.jsonValue);
        } catch (_) {
          // fall through to text handling
        }
      }
      if (typeof part?.text === 'string' && part.text.trim()) {
        return part.text;
      }
      if (part?.functionCall) {
        try {
          return JSON.stringify(part.functionCall);
        } catch (_) {
          // ignore parse issues
        }
      }
    }
  }
  const contents = response?.contents;
  if (Array.isArray(contents)) {
    for (const content of contents) {
      if (Array.isArray(content?.parts)) {
        for (const part of content.parts) {
          if (part?.jsonValue && typeof part.jsonValue === 'object') {
            try {
              return JSON.stringify(part.jsonValue);
            } catch (_) {
              // ignore
            }
          }
          if (typeof part?.text === 'string' && part.text.trim()) {
            return part.text;
          }
        }
      }
    }
  }
  return '';
}

function normalizeA2UIComponents(parsed, fallbackText = '') {
  const toMessage = (content) => ([{ type: 'message', content: String(content || '').trim() }].filter(x => x.content));

  if (Array.isArray(parsed)) {
    const out = [];
    for (const item of parsed) {
      if (item && typeof item === 'object') {
        if (typeof item.type === 'string' && item.type.trim()) {
          out.push(item);
        } else {
          out.push({ type: 'message', content: JSON.stringify(item) });
        }
      } else if (typeof item === 'string' && item.trim()) {
        out.push({ type: 'message', content: item });
      }
    }
    return out.length ? out : toMessage(fallbackText);
  }

  if (parsed && typeof parsed === 'object') {
    if (typeof parsed.type === 'string' && parsed.type.trim()) return [parsed];
    return toMessage(fallbackText || JSON.stringify(parsed));
  }

  if (typeof parsed === 'string') return toMessage(parsed);
  return toMessage(fallbackText);
}

function stripMarkdownFences(text) {
  const t = String(text || '').trim();
  if (!t) return '';
  if (!t.startsWith('```')) return t;
  return t.replace(/^```[a-zA-Z]*\s*/, '').replace(/\s*```$/, '').trim();
}

function tryParseJsonMaybe(text) {
  const cleaned = stripMarkdownFences(text);
  if (!cleaned) return null;
  // First attempt
  try {
    const first = JSON.parse(cleaned);
    // Some SDKs may wrap JSON as a string
    if (typeof first === 'string') {
      const inner = first.trim();
      if ((inner.startsWith('[') && inner.endsWith(']')) || (inner.startsWith('{') && inner.endsWith('}'))) {
        try {
          return JSON.parse(inner);
        } catch (_) {
          return first;
        }
      }
    }
    return first;
  } catch (_) {
    // Heuristic: extract the outermost JSON array/object substring
    const s = cleaned;
    const firstArr = s.indexOf('[');
    const lastArr = s.lastIndexOf(']');
    if (firstArr >= 0 && lastArr > firstArr) {
      const sub = s.slice(firstArr, lastArr + 1);
      try { return JSON.parse(sub); } catch (_) {}
    }
    const firstObj = s.indexOf('{');
    const lastObj = s.lastIndexOf('}');
    if (firstObj >= 0 && lastObj > firstObj) {
      const sub = s.slice(firstObj, lastObj + 1);
      try { return JSON.parse(sub); } catch (_) {}
    }
    return null;
  }
}

function sanitizeA2UIComponents(components) {
  const out = [];
  const pushMessage = (content) => {
    const c = String(content || '').trim();
    if (c) out.push({ type: 'message', content: c });
  };

  const toStringArray = (value) => {
    if (!Array.isArray(value)) return [];
    return value.map(v => String(v ?? '').trim()).filter(Boolean).slice(0, 12);
  };

  const toString = (value) => String(value ?? '').trim();

  const items = Array.isArray(components) ? components : [];
  for (const raw of items) {
    if (!raw || typeof raw !== 'object') continue;
    const type = toString(raw.type);

    if (type === 'message') {
      const content = toString(raw.content);
      if (content) {
        // If content itself looks like JSON, try to recover instead of showing raw JSON.
        const maybe = tryParseJsonMaybe(content);
        if (Array.isArray(maybe)) {
          const recovered = sanitizeA2UIComponents(maybe);
          if (recovered.length) {
            out.push(...recovered);
            continue;
          }
        }
        pushMessage(content);
      }
      continue;
    }

    if (type === 'quickReplies') {
      const quickReplies = toStringArray(raw.quickReplies);
      if (quickReplies.length) out.push({ type: 'quickReplies', quickReplies });
      continue;
    }

    if (type === 'tip') {
      const title = toString(raw.title) || 'Tip';
      const description = toString(raw.description);
      if (description) out.push({ type: 'tip', title, description });
      continue;
    }

    if (type === 'recipe') {
      const title = toString(raw.title) || 'Recipe';
      const ingredients = toStringArray(raw.ingredients);
      const instructions = toStringArray(raw.instructions);
      const calories = toString(raw.calories);
      const carbs = toString(raw.carbs);
      const protein = toString(raw.protein);
      const fat = toString(raw.fat);
      const weight = toString(raw.weight);
      const sourceUrl = toString(raw.sourceUrl);
      if (ingredients.length && instructions.length) {
        out.push({
          type: 'recipe',
          title,
          ingredients,
          instructions,
          calories,
          carbs,
          protein,
          fat,
          weight,
          sourceUrl,
        });
      } else {
        pushMessage(`I couldn't format a full recipe for "${title}". Try asking again with more specifics.`);
      }
      continue;
    }

    // Unknown type: reduce to a safe message.
    try {
      pushMessage(JSON.stringify(raw));
    } catch (_) {
      // ignore
    }
  }

  return out.length ? out : [{ type: 'message', content: 'Sorry, I had trouble formatting that response. Please try again.' }];
}

async function englishNormalizeWithFlash(ai, originalJsonish) {
  try {
    const payload = typeof originalJsonish === 'string' ? originalJsonish : JSON.stringify(originalJsonish);
    const response = await ai.models.generateContent({
      model: 'gemini-2.5-flash',
      contents: [
        {
          role: 'user',
          parts: [
            {
              text: `Verify the following JSON is fully English. If not, translate values to English and return the JSON unchanged in structure and keys. Return JSON only.\n\nJSON:\n${payload}`,
            },
          ],
        },
      ],
      systemInstruction: normalizationInstruction,
      safetySettings,
      config: {
        ...generationDefaults,
        responseMimeType: 'application/json',
        responseSchema: nutritionResponseSchema,
      },
    });
    const text = extractResponseText(response).trim();
    if (!text) return null;
    const data = JSON.parse(text);
    if (data && typeof data === 'object') {
      return data;
    }
    return null;
  } catch (e) {
    try {
      console.warn('englishNormalizeWithFlash failed:', e?.message ?? e);
    } catch (_) { }
    return null;
  }
}

async function handleVertexRequest(req, res) {
  if (!vertexApiKey) {
    console.warn('Vertex mode requested but VERTEX_API_KEY not found.');
    return handleRequestWithRetry(req, res);
  }

  // Temporarily enable Vertex mode for the SDK
  process.env.GOOGLE_GENAI_USE_VERTEXAI = 'true';
  const ai = new GoogleGenAI({ apiKey: vertexApiKey });
  // Unset immediately to prevent polluting other requests/fallbacks
  delete process.env.GOOGLE_GENAI_USE_VERTEXAI;

  try {
    const { file } = req;
    const { message, lang } = req.body ?? {};
    const acceptLangHeader = (req.get('accept-language') || '').split(',')[0].trim().toLowerCase();
    const locale = (typeof lang === 'string' && lang.trim())
      ? lang.trim().toLowerCase()
      : (acceptLangHeader || 'en');
    const isEnglishLocale = (
      (typeof lang === 'string' && lang.trim().toLowerCase().startsWith('en')) ||
      (typeof acceptLangHeader === 'string' && acceptLangHeader.startsWith('en'))
    );

    const rawMessage = typeof message === 'string' ? message : '';
    const trimmedMessage = rawMessage.trim();
    if (!file && trimmedMessage.length === 0) {
      return res.status(400).json({ ok: false, error: 'No input provided. Please include a message and/or an image.' });
    }

    let imagePart = null;
    if (file) {
      try {
        imagePart = await buildInlineImagePart(file);
      } catch (imageError) {
        try {
          console.warn('Vertex: Failed to prepare uploaded image:', imageError?.message ?? imageError);
        } catch (_) { }
      }
    }

    const parts = [];
    if (imagePart) {
      parts.push(imagePart);
    }
    if (rawMessage.length > 0 || parts.length === 0) {
      parts.push({ text: rawMessage });
    }
    const userPrompt = rawMessage;

    const systemInstructionText = [
      'You cannot base yourself off typical serving sizes, only visual information and deep picture analysis of weight.',
      'You must find the exact weight to the gram. Also remove ~10% of your estimated weight guess.',
      'Always choose your minimum guess; if you estimate a range like 213-287, always pick the lowest number.',
      `Reply in: ${locale === 'fr' ? 'french' : 'english'}.`,
    ].join(' ');

    const systemInstruction = {
      role: 'system',
      parts: [{ text: systemInstructionText }],
    };

    try {
      console.log('[Vertex AI] systemInstruction ->', systemInstructionText);
      console.log('[Vertex AI] user prompt ->', userPrompt);
    } catch (_) { }

    const response = await ai.models.generateContent({
      model: 'gemini-3-pro-preview',
      contents: [
        {
          role: 'user',
          parts,
        },
      ],
      systemInstruction,
      safetySettings,
      config: {
        ...generationDefaults,
        responseMimeType: 'application/json',
        responseSchema: nutritionResponseSchema,
      },
    });

    let text = extractResponseText(response);
    if (text && text.trim().startsWith('```')) {
      text = text.replace(/^```[a-zA-Z]*\s*/, '').replace(/\s*```$/, '');
    }
    text = typeof text === 'string' ? text.trim() : '';

    try {
      console.log(`[Vertex AI][gemini-3-pro-preview] raw: ${text}`);
    } catch (_) { }

    let data = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch (_) {
        data = null;
      }
    }

    if ((text && text.trim()) || (data && typeof data === 'object' && Object.keys(data).length > 0)) {
      let finalPayload = (data && typeof data === 'object') ? data : text;
      if (isEnglishLocale) {
        try {
          const normalized = await englishNormalizeWithFlash(ai, finalPayload);
          if (normalized) {
            finalPayload = normalized;
          }
        } catch (_) {
          // keep original payload
        }
      }
      await logRequestIp(req);
      return res.json({ ok: true, data: finalPayload });
    }

    throw new Error('Vertex AI returned no content.');

  } catch (error) {
    console.warn('Vertex AI failed, reverting to standard API:', error?.message ?? error);
    // Ensure Vertex mode is off for fallback
    if (process.env.GOOGLE_GENAI_USE_VERTEXAI) delete process.env.GOOGLE_GENAI_USE_VERTEXAI;
    return handleRequestWithRetry(req, res);
  }
}

async function handleRequestWithRetry(req, res, attempt = 0) {
  const keysToTry = [];
  if (specialKey) keysToTry.push({ key: specialKey, isSpecial: true });
  // Add normal keys, rotating starting from current index
  for (let i = 0; i < apiKeys.length; i++) {
    keysToTry.push({ key: apiKeys[(currentApiKeyIndex + i) % apiKeys.length], isSpecial: false });
  }
  // Advance rotation for next request
  if (apiKeys.length > 0) {
    currentApiKeyIndex = (currentApiKeyIndex + 1) % apiKeys.length;
  }

  if (keysToTry.length === 0) {
    return res.status(503).json({ ok: false, error: 'Service is currently unavailable, please try again later.' });
  }
  
  // If we are in a recursive retry (attempt > 0), we might want to skip the special key if it was already tried?
  // But handleRequestWithRetry is recursive with 'attempt' index.
  // Let's just use the 'attempt' index to pick from our constructed list.
  
  if (attempt >= keysToTry.length) {
    return res.status(503).json({ ok: false, error: 'Service is currently unavailable, please try again later.' });
  }

  const { key: apiKey, isSpecial } = keysToTry[attempt];
  const ai = new GoogleGenAI({ apiKey });

  try {
    const { file } = req;
    const { message, lang } = req.body ?? {};
    const acceptLangHeader = (req.get('accept-language') || '').split(',')[0].trim().toLowerCase();
    const locale = (typeof lang === 'string' && lang.trim())
      ? lang.trim().toLowerCase()
      : (acceptLangHeader || 'en');
    const isEnglishLocale = (
      (typeof lang === 'string' && lang.trim().toLowerCase().startsWith('en')) ||
      (typeof acceptLangHeader === 'string' && acceptLangHeader.startsWith('en'))
    );
    const useFlash = String(req.query.flash || '0') === '1';

    const rawMessage = typeof message === 'string' ? message : '';
    const trimmedMessage = rawMessage.trim();
    if (!file && trimmedMessage.length === 0) {
      return res.status(400).json({ ok: false, error: 'No input provided. Please include a message and/or an image.' });
    }

    let imagePart = null;
    if (file) {
      try {
        imagePart = await buildInlineImagePart(file);
      } catch (imageError) {
        try {
          console.warn('Failed to prepare uploaded image:', imageError?.message ?? imageError);
        } catch (_) { }
      }
    }

    const parts = [];
    if (imagePart) {
      parts.push(imagePart);
    }
    if (rawMessage.length > 0 || parts.length === 0) {
      parts.push({ text: rawMessage });
    }
    const userPrompt = rawMessage;

    const contents = [
      {
        role: 'user',
        parts,
      },
    ];

    const systemInstructionText = [
      'You cannot base yourself off typical serving sizes, only visual information and deep picture analysis of weight.',
      'You must find the exact weight to the gram. Also remove ~10% of your estimated weight guess.',
      'Always choose your minimum guess; if you estimate a range like 213-287, always pick the lowest number.',
      `Reply in: ${locale === 'fr' ? 'french' : 'english'}.`,
    ].join(' ');

    const systemInstruction = {
      role: 'system',
      parts: [{ text: systemInstructionText }],
    };

    try {
      console.log('[AI] systemInstruction ->', systemInstructionText);
      console.log('[AI] user prompt ->', userPrompt);
    } catch (_) { }

    // Special key uses gemini-3-pro-preview, others use gemini-3-flash-preview (unless flash query param overrides)
    let modelName = useFlash ? 'gemini-2.5-flash' : 'gemini-3-flash-preview';
    if (isSpecial && !useFlash) {
      modelName = 'gemini-3-pro-preview';
    }

    for (let i = 0; i < 10; i += 1) {
      const response = await ai.models.generateContent({
        model: modelName,
        contents,
        systemInstruction,
        safetySettings,
        config: {
          ...generationDefaults,
          responseMimeType: 'application/json',
          responseSchema: nutritionResponseSchema,
        },
      });

      let text = extractResponseText(response);
      if (text && text.trim().startsWith('```')) {
        text = text.replace(/^```[a-zA-Z]*\s*/, '').replace(/\s*```$/, '');
      }
      text = typeof text === 'string' ? text.trim() : '';

      try {
        console.log(`[AI][${modelName}][try ${i + 1}/10] raw: ${text}`);
      } catch (_) { }

      let data = null;
      if (text) {
        try {
          data = JSON.parse(text);
        } catch (_) {
          data = null;
        }
      }

      if ((text && text.trim()) || (data && typeof data === 'object' && Object.keys(data).length > 0)) {
        let finalPayload = (data && typeof data === 'object') ? data : text;
        if (isEnglishLocale) {
          try {
            const normalized = await englishNormalizeWithFlash(ai, finalPayload);
            if (normalized) {
              finalPayload = normalized;
            }
          } catch (_) {
            // keep original payload
          }
        }
        await logRequestIp(req);
        return res.json({ ok: true, data: finalPayload });
      }
    }

    console.warn('Model returned no content after 10 tries');
    // If we failed 10 times with this key/model, try next key
    if (attempt + 1 < keysToTry.length) {
      return handleRequestWithRetry(req, res, attempt + 1);
    }
    return res.status(503).json({ ok: false, error: 'Empty response from model after retries.' });
  } catch (error) {
    console.error(`Error with API key ${apiKey} (special=${isSpecial}):`, error);
    const status = error?.status ?? error?.response?.status ?? 0;
    // Retry on error if we have more keys
    if (attempt + 1 < keysToTry.length) {
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
const PASSWORD_AUTH = (() => {
  const v = String(process.env.PASSWORD_AUTH ?? process.env.password_auth ?? 'true').toLowerCase();
  return !(v === 'false' || v === '0' || v === 'off' || v === 'no');
})();

app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use('/static', express.static(path.join(__dirname, 'assets')));

function requireToken(req, res, next) {
  const headerToken = req.get('x-app-token');
  const bearer = req.get('authorization');
  const bearerToken = bearer && /^Bearer\s+(.+)/i.test(bearer) ? bearer.replace(/^Bearer\s+/i, '') : undefined;
  const token = headerToken || bearerToken;
  if (token !== APP_TOKEN) {
    return res.status(401).json({ ok: false, error: 'Unauthorized' });
  }
  return next();
}

app.use(cors());
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
    try { console.warn('request ip log failed', e && e.message ? e.message : e); } catch (_) { }
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
    if (!username || String(username).length < 3) return res.status(400).json({ ok: false, error: 'username too short' });
    const pool = await dbPoolPromise;
    // Generate temporary password
    const temp = Math.random().toString(36).slice(2, 10);
    const hash = await bcrypt.hash(temp, 10);
    await pool.query('INSERT INTO users (username, password_hash, force_password_reset) VALUES (?, ?, 1) ON DUPLICATE KEY UPDATE force_password_reset=VALUES(force_password_reset), password_hash=VALUES(password_hash)', [username, hash]);
    res.json({ ok: true, username, temporaryPassword: temp });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok: false, error: 'invite failed' });
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
    res.json({
      ok: true, settings: {
        // Backward compat: announcement_md kept if present; new fields preferred
        announcement_md: map.announcement_md || '',
        announcement_md_en: map.announcement_md_en || map.announcement_md || '',
        announcement_md_fr: map.announcement_md_fr || '',
        discord_url: map.discord_url || '',
        github_issues_url: map.github_issues_url || ''
      }
    });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok: false, error: 'load settings failed' });
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
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok: false, error: 'save settings failed' });
  }
});

// Auth routes
app.post('/auth/login', async (req, res) => {
  try {
    const { username, password } = req.body || {};
    if (!username || !password) return res.status(400).json({ ok: false, error: 'missing credentials' });
    const pool = await dbPoolPromise;
    const [rows] = await pool.query('SELECT * FROM users WHERE username=? LIMIT 1', [username]);
    if (!Array.isArray(rows) || rows.length === 0) return res.status(401).json({ ok: false, error: 'invalid credentials' });
    const user = rows[0];
    const ok = await bcrypt.compare(password, user.password_hash);
    if (!ok) return res.status(401).json({ ok: false, error: 'invalid credentials' });
    const token = signToken(user);
    res.json({ ok: true, token, forcePasswordReset: !!user.force_password_reset });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok: false, error: 'login failed' });
  }
});

app.post('/auth/set-password', authJwt, async (req, res) => {
  try {
    const { newPassword } = req.body || {};
    if (!newPassword || String(newPassword).length < 6) return res.status(400).json({ ok: false, error: 'password too short' });
    const pool = await dbPoolPromise;
    const hash = await bcrypt.hash(newPassword, 10);
    await pool.query('UPDATE users SET password_hash=?, force_password_reset=0 WHERE id=?', [hash, req.user.sub]);
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok: false, error: 'set-password failed' });
  }
});

// Existing endpoints: protect with both JWT (user logged-in) and app token for model calls
if (PASSWORD_AUTH) {
  app.get('/ping', authJwt, (req, res) => res.json({ ok: true, pong: true }));
  app.post('/ping', authJwt, (req, res) => res.json({ ok: true, pong: true }));
} else {
  app.get('/ping', (req, res) => res.json({ ok: true, pong: true }));
  app.post('/ping', (req, res) => res.json({ ok: true, pong: true }));
}

const upload = multer({
  storage: multer.memoryStorage(),
});
const modelGuards = PASSWORD_AUTH ? [authJwt, requireToken] : [requireToken];

app.post('/chat', ...modelGuards, async (req, res) => {
  try {
    const { message, history, lang } = req.body || {};
    if (typeof message !== 'string' || !message.trim()) {
      return res.status(400).json({ error: 'message is required' });
    }

    const acceptLang = (req.get('accept-language') || '').split(',')[0].trim().toLowerCase();
    const bodyLang = (typeof lang === 'string' ? lang.trim().toLowerCase() : '');
    const resolvedLang = (bodyLang === 'fr' || bodyLang.startsWith('fr'))
      ? 'fr'
      : ((bodyLang === 'en' || bodyLang.startsWith('en'))
        ? 'en'
        : (acceptLang.startsWith('fr') ? 'fr' : 'en'));
    const replyLanguage = resolvedLang === 'fr' ? 'french' : 'english';

    try {
      console.log('[chat] incoming', {
        message: message?.slice ? message.slice(0, 120) : message,
        hasHistory: Array.isArray(history),
        ip: getClientIp(req),
      });
    } catch (_) { /* ignore logging errors */ }

    if (!apiKeys || apiKeys.length === 0) {
      return res.status(503).json({ error: 'No API keys configured' });
    }

    const baseHistory = history && Array.isArray(history) ? history : [
      {
        role: 'user',
        parts: [{ text: 'You are a helpful nutrition assistant. You help users with diets, recipes, and healthy eating tips. You must output JSON.' }],
      },
      {
        role: 'model',
        parts: [{ text: '[]' }],
      }
    ];

    const contents = [
      ...baseHistory,
      {
        role: 'user',
        parts: [{ text: message }],
      },
    ];

    const systemInstruction = {
      role: 'system',
      parts: [{
        text: [
          'You are a nutrition assistant.',
          `Reply in: ${replyLanguage}.`,
          'You must reply to the recipe request with quick replies first.',
          'You MUST prompt the user on which recipe to choose, give them options using the quickReplies component type, YOU MUST USE IT. Even if the user asks just for pasta recipe, give it choice and ALWAYS.',
          'Always return an array of components.',
          'you must take the recipes from google, put the links in source.',
          'IMPORTANT: Follow the schema strictly. Never invent extra keys.',
          'Allowed shapes:',
          '- message: {"type":"message","content":"..."} (ONLY these keys).',
          '- quickReplies: {"type":"quickReplies","quickReplies":["..."]} (ONLY these keys).',
          '- tip: {"type":"tip","title":"...","description":"..."} (ONLY these keys).',
          '- recipe: {"type":"recipe","title":"...","ingredients":["..."],"instructions":["..."],"calories":"...", optional "carbs","protein","fat","weight","sourceUrl"}.',
          'Use type="message" with a helpful string when unsure.',
          'Use type="quickReplies" to offer quick replies (buttons).',
          'To display buttons, you MUST include a component with type="quickReplies". Text alone does not create buttons.',
          'Whenever you ask a clarifying question, provide relevant options in a "quickReplies" component.',
          'CRITICAL: If the user asks for a generic dish (e.g. "pasta", "salad", "soup") or ingredient, DO NOT provide a recipe immediately. Instead, use type="quickReplies" to ask for specifics (e.g. "Carbonara", "Bolognese", "Pesto").',
          'Only provide a recipe when the user request is specific.',
          'Do not include markdown fences.',
        ].join(' '),
      }],
    };

    let lastError;
    let attempts = 0;
    const keysToTry = [];
    if (specialKey) keysToTry.push({ key: specialKey, isSpecial: true });
    apiKeys.forEach(k => keysToTry.push({ key: k, isSpecial: false }));

    for (const { key, isSpecial } of keysToTry) {
      attempts++;
      const ai = new GoogleGenAI({ apiKey: key });
      try {
        const config = {
          ...generationDefaults,
          responseMimeType: 'application/json',
          responseSchema: chatResponseSchema,
          systemInstruction,
          safetySettings,
        };
        // Only enable tools for the special key
        if (isSpecial) {
          config.tools = [{ googleSearch: {} }, { urlContext: {} }];
        }

        const modelResponse = await ai.models.generateContent({
          model: 'gemini-3-flash-preview',
          contents,
          config,
        });

        const rawText = extractResponseText(modelResponse);
        const parsed = tryParseJsonMaybe(rawText);
        const normalized = normalizeA2UIComponents(parsed, rawText);
        const sanitized = sanitizeA2UIComponents(normalized);
        try {
          const types = sanitized.map(c => c.type).join(', ');
          console.log(
            `[chat] success (${Array.isArray(parsed)
              ? 'array'
              : (parsed && typeof parsed === 'object' ? 'object' : 'other')}) -> ${normalized.length} components: [${types}]`
          );
        } catch (_) {}
        return res.json(sanitized);
      } catch (err) {
        lastError = err;
        const status = err?.status ?? err?.response?.status ?? 0;
        // If special key fails, we always continue to normal keys.
        // If normal key fails, we retry only on transient errors.
        const shouldRetry = isSpecial || ((status === 429 || status === 500 || status === 503) && (attempts < keysToTry.length));
        if (!shouldRetry) break;
      }
    }

    console.error('Chat error (all keys failed):', lastError);
    return res.status(500).json({ error: lastError?.message || 'chat failed' });
  } catch (error) {
    console.error('Chat error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.post('/data', ...modelGuards, upload.single('image'), async (req, res) => {
  try {
    const { message } = req.body || {};
    if (typeof message === 'string' && message.toLowerCase().includes('ping')) {
      await logRequestIp(req);
      return res.json({ ok: true, data: { echo: message, note: 'fast-path' } });
    }
  } catch (_) { }
  if (useVertexArg) {
    return handleVertexRequest(req, res);
  }
  return handleRequestWithRetry(req, res);
});

// Admin: downloadable IP report (last 24h)
app.get('/admin/ip-report', requireAdmin, async (req, res) => {
  try {
    const pool = await dbPoolPromise;
    const [rows] = await pool.query(
      'SELECT ip, COUNT(*) AS cnt FROM request_logs WHERE created_at >= (NOW() - INTERVAL 1 DAY) GROUP BY ip ORDER BY cnt DESC'
    );
    const lines = Array.isArray(rows) ? rows.map(r => `${r.ip}\t${r.cnt}`).join('\n') : '';
    const fname = `ip_report_${new Date().toISOString().slice(0, 10)}.txt`;
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
    res.status(500).json({ ok: false, error: 'announcement failed' });
  }
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running at http://0.0.0.0:${PORT}`);
});