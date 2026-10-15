// supabaseClient.js — يقرأ إعدادات config.js ويجهّز الاتصال بـ Supabase (لا تعدّل فيه شيئاً).
(function () {
  var cfg = window.APP_CONFIG || {};
  var url = (cfg.SUPABASE_URL || "").trim();
  var key = (cfg.SUPABASE_ANON_KEY || "").trim();
  var configError = null;

  if (!window.supabase || typeof window.supabase.createClient !== "function") {
    configError = "تعذّر تحميل مكتبة Supabase من الإنترنت. تحقق من الاتصال ثم أعد تحميل الصفحة.";
  } else if (!url || !key || url.indexOf("ضع-") === 0 || key.indexOf("ضع-") === 0) {
    configError = "لم تضع رابط المشروع والمفتاح بعد. افتح ملف config.js بالنوت باد واكتب القيمتين ثم احفظه وأعد تحميل الصفحة.";
  } else if (!/^https:\/\/.+\.supabase\.co\/?$/.test(url)) {
    configError = "رابط المشروع في config.js غير صحيح. يجب أن يشبه: https://xxxxxxxx.supabase.co";
  }

  var client = null;
  if (!configError) {
    client = window.supabase.createClient(url, key, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
    });
  }
  window.APP = { supabase: client, configError: configError };
})();
