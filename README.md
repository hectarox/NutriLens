# NutriLens app + backend

## Backend setup

1) Configure environment in `.env` (create it if missing):

```
# Server
PORT=3000
APP_TOKEN=<choose-a-strong-shared-secret> # Can be anything, think of it as a password, save it for later
JWT_SECRET=<choose-a-strong-jwt-secret> # Can be anything, think of it as a password
APP_BASE_URL=http://<external_ip>
APP_PORT=3000 #same as server port
GEMINI_API_KEYS=<key1,key2,...> #get them at https://aistudio.google.com

# Auth setup (for inviting users)
ADMIN_USER=<Username>
ADMIN_PASSWORD=<Password>

# Database setup
DB_HOST=<mysql-host>
DB_PORT=3306
DB_USER=<mysql-user>
DB_PASSWORD=<mysql-password>
DB_NAME=<mysql-database>



```

2) Install and run

```
npm install
npm start
```

3) Open the admin panel at http://<server-ip>:3000/
- You’ll be prompted for HTTP Basic Auth (set ADMIN_USER / ADMIN_PASSWORD in .env).
- Use the Invite form; it returns a temporary password for the new user.

If MySQL is remote, ensure port 3306 is open and login is permitted from the backend machine. The backend will create the database and tables on first run.

### Environment variables

- PORT: HTTP port for backend
- APP_TOKEN: Shared secret; the app must send this as x-app-token on /data
- JWT_SECRET: Secret to sign JWTs (set a strong value in production)
- DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME: MySQL connection
- GEMINI_API_KEYS: Comma-separated Google Gemini API keys. Create keys at https://aistudio.google.com.
- ADMIN_USER / ADMIN_PASSWORD: HTTP Basic Auth credentials to access the admin panel.
- APP_BASE_URL/APP_PORT: For documentation; the Flutter app uses .env.client

## API summary

- POST /auth/login { username, password } -> { ok, token, forcePasswordReset }
- POST /auth/set-password (Bearer token) { newPassword } -> { ok }
- GET/POST /ping (Bearer token) -> { ok, pong:true }
- POST /data (Bearer token + x-app-token) multipart fields: message, image -> { ok, data }

Note: /data requires the shared secret header: `x-app-token: change_me`.

## App setup (Flutter)

1) Configure `.env.client` (create it if missing):

```
APP_BASE_URL=http://<server-host>:<port> #as in the other .env
APP_TOKEN=<same-as-backend-APP_TOKEN> #same as the other .env
```

2) Install dependencies and run

```
flutter pub get
flutter run
```

3) Build a release APK

```
flutter build apk --release
```

4) Login flow

- Use the admin panel to invite a username; note the temporary password.
- In the app, login with these credentials.
- If prompted to set a new password, complete that step; the app will route to the main screen afterward.


