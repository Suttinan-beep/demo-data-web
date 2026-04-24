import { getUserId } from "./supabase-client.js";

export { getUserId };

export function getNickname() {
  return ["currentNickname", "nickname", "NickName", "nick", "Nick"]
    .map((key) => localStorage.getItem(key))
    .find(Boolean);
}

export function requireLogin() {
  const uid = localStorage.getItem("userId");
  const alive = sessionStorage.getItem("alive");

  if (!uid || !alive) {
    localStorage.clear();
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

export function renderUserInfo(elementId, fallbackName = "ผู้ใช้") {
  const uid = getUserId();
  const nick = getNickname();
  const el = document.getElementById(elementId);

  if (uid && el) {
    el.textContent = `👤 ${nick || fallbackName} (User ID: ${uid})`;
  }
}
