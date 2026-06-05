import { getAppSessionToken, getUserId, supabase } from "./supabase-client.js";

export { getAppSessionToken, getUserId };

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
  const appSessionExpiresAt = sessionStorage.getItem("appSessionExpiresAt");
  const appSessionExpiresMs = Date.parse(appSessionExpiresAt || "");
  const appSessionExpired = !Number.isFinite(appSessionExpiresMs) || appSessionExpiresMs <= Date.now();

  if (!uid || !alive || !appSessionToken || appSessionExpired) {
    localStorage.clear();
    sessionStorage.clear();
    window.location.href = "Index.html";
    return false;
  }

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
