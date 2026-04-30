import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

export const SUPABASE_URL = "https://ihfxsyxzjgolhfumemiw.supabase.co";
export const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImloZnhzeXh6amdvbGhmdW1lbWl3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTU3MDEwNDksImV4cCI6MjA3MTI3NzA0OX0.dPtOjlr6N3WEclJ2rcQ0HkWtGDLgn-qdQlKGa4DCe9o";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export function getUserId() {
  return ["currentUserID", "currentUserId", "userId", "userid"]
    .map((key) => localStorage.getItem(key))
    .find(Boolean);
}

export function getAppSessionToken() {
  return sessionStorage.getItem("appSessionToken");
}
