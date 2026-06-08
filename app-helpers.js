import { getAppSessionToken, getUserId, supabase } from "./supabase-client.js";

export { getAppSessionToken, getUserId };

const IDLE_TIMEOUT_MS = 15 * 60 * 1000;
const SESSION_REFRESH_INTERVAL_MS = 60 * 1000;
let keepAliveStarted = false;
let refreshInFlight = false;
let lastRefreshAttemptMs = 0;

function parseStoredTime(key) {
  const value = sessionStorage.getItem(key);
  const ms = Date.parse(value || "");
  return Number.isFinite(ms) ? ms : 0;
}

function redirectToLogin() {
  localStorage.clear();
  sessionStorage.clear();
  window.location.href = "Index.html";
}

function getLastActivityMs() {
  const stored = Number(sessionStorage.getItem("appLastActivityAt") || "");
  return Number.isFinite(stored) && stored > 0 ? stored : Date.now();
}

function markAppActivity() {
  sessionStorage.setItem("appLastActivityAt", String(Date.now()));
  void refreshAppSession();
}

async function refreshAppSession(force = false) {
  const token = getAppSessionToken();
  const now = Date.now();
  const lastActivityMs = getLastActivityMs();
  const maxExpiresMs = parseStoredTime("appSessionMaxExpiresAt");

  if (!token || refreshInFlight) return false;
  if (maxExpiresMs && maxExpiresMs <= now) {
    redirectToLogin();
    return false;
  }
  if (now - lastActivityMs > IDLE_TIMEOUT_MS) {
    redirectToLogin();
    return false;
  }
  if (!force && now - lastRefreshAttemptMs < SESSION_REFRESH_INTERVAL_MS) return true;

  refreshInFlight = true;
  lastRefreshAttemptMs = now;

  const { data, error } = await supabase.rpc("touch_app_user_session", {
    p_session_token: token,
  });

  refreshInFlight = false;

  if (error) {
    console.error("Session refresh error:", error);
    return false;
  }

  const session = Array.isArray(data) ? data[0] : data;
  if (!session?.expires_at) {
    redirectToLogin();
    return false;
  }

  sessionStorage.setItem("appSessionExpiresAt", session.expires_at || "");
  sessionStorage.setItem("appSessionMaxExpiresAt", session.max_expires_at || "");
  return true;
}

function initAppSessionKeepAlive() {
  if (keepAliveStarted) return;
  keepAliveStarted = true;

  if (!sessionStorage.getItem("appLastActivityAt")) {
    sessionStorage.setItem("appLastActivityAt", String(Date.now()));
  }

  ["click", "keydown", "pointerdown", "touchstart", "scroll"].forEach((eventName) => {
    window.addEventListener(eventName, markAppActivity, { passive: true });
  });

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      markAppActivity();
    }
  });

  window.setInterval(() => {
    void refreshAppSession();
  }, SESSION_REFRESH_INTERVAL_MS);

  void refreshAppSession(true);
}

export function getNickname() {
  return ["currentNickname", "nickname", "NickName", "nick", "Nick"]
    .map((key) => localStorage.getItem(key))
    .find(Boolean);
}

export function getDepartment() {
  return ["department", "Department", "dept", "Dept"]
    .map((key) => localStorage.getItem(key))
    .find(Boolean);
}

export function requireLogin() {
  const uid = localStorage.getItem("userId");
  const alive = sessionStorage.getItem("alive");
  const appSessionToken = getAppSessionToken();
  const now = Date.now();
  const appSessionExpiresMs = parseStoredTime("appSessionExpiresAt");
  const appSessionMaxExpiresMs = parseStoredTime("appSessionMaxExpiresAt");
  const lastActivityMs = getLastActivityMs();
  const appSessionExpired = !appSessionExpiresMs || appSessionExpiresMs <= now;
  const appSessionMaxExpired = Boolean(appSessionMaxExpiresMs) && appSessionMaxExpiresMs <= now;
  const appSessionIdleExpired = now - lastActivityMs > IDLE_TIMEOUT_MS;

  if (!uid || !alive || !appSessionToken || appSessionExpired || appSessionMaxExpired || appSessionIdleExpired) {
    redirectToLogin();
    return false;
  }

  initAppSessionKeepAlive();
  return true;
}

export function requirePageFlag(flagName, redirectPath, message) {
  if (sessionStorage.getItem(flagName) === "true") {
    return true;
  }

  if (message) {
    alert(message);
  }
  window.location.href = redirectPath;
  return false;
}

export async function hasMenuAccess(menuCode) {
  const sessionToken = getAppSessionToken();
  if (!sessionToken || !menuCode) return false;

  const { data, error } = await supabase.rpc("check_menu_access_for_session", {
    p_session_token: sessionToken,
    p_menu_code: menuCode,
  });

  if (error) {
    console.error("Menu access error:", error);
    return false;
  }

  const result = Array.isArray(data) ? data[0] : data;
  return result?.has_access === true;
}

export async function requireMenuAccess(menuCode, redirectPath = "Menu.html", message = "Access denied") {
  const allowed = await hasMenuAccess(menuCode);

  if (allowed) {
    return true;
  }

  if (message) {
    alert(message);
  }

  window.location.href = redirectPath;
  return false;
}

export function nowStr() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

export async function insertStory(supabaseClient, action, detail) {
  const payload = {
    created_at: nowStr(),
    User_ID_FK: getUserId(),
    Story: action,
    Orders: detail,
  };

  const { error } = await supabaseClient.from("Storyline").insert([payload]);
  return { payload, error };
}

export function renderUserInfo(elementId, fallbackName = "User") {
  const uid = getUserId();
  const nick = getNickname();
  const el = document.getElementById(elementId);

  if (uid && el) {
    el.textContent = `${nick || fallbackName} (User ID: ${uid})`;
  }
}

export function renderUserHeader(userIdElementId, detailElementId, fallbackName = "User") {
  const uid = getUserId();
  const nick = getNickname();
  const dept = getDepartment();
  const userIdEl = document.getElementById(userIdElementId);
  const detailEl = document.getElementById(detailElementId);

  if (userIdEl) {
    userIdEl.textContent = uid || "-";
  }

  if (detailEl) {
    const displayName = nick || fallbackName;
    detailEl.textContent = dept ? `${displayName} (${dept})` : displayName;
  }
}
