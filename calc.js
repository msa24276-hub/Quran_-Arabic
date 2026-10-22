// calc.js — دوال الحساب والعرض المشتركة (تُختبر بشكل مستقل في tests/).
// القاعدة: المدد تُخزَّن بالدقائق وتُجمع بالدقائق، ولا يُقرَّب أي شيء إلا عند العرض فقط.
(function (root) {
  var f2 = function (n, d) {
    if (d === undefined) d = 2;
    return Number(n).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
  };
  // مبالغ الحصة الواحدة: حتى 4 خانات (بلا أصفار زائدة) حتى لا يضيع جزء من السنت عند العرض
  var f4 = function (n) {
    return Number(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 });
  };
  // الساعات: حتى خانتين عشريتين، بلا أصفار زائدة (0.25 / 2.5 / 262.5 / 3)
  var fh = function (h) {
    return Number(h).toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  };
  var ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  var esc = function (s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return ESC[c]; });
  };
  // المدة المحتسبة بالدقائق: حضر = مدة الحصة، غاب محتسب = مدة الحصة، غاب غير محتسب = 0
  var cmOf = function (l) { return l.cm !== undefined ? l.cm : (l.st == "p" ? l.m : 0); };
  var hrs = function (a) {
    var mins = 0;
    for (var i = 0; i < a.length; i++) mins += cmOf(a[i]);
    return mins / 60;
  };
  var wage = function (l) { return cmOf(l) / 60 * l.r; };   // أجر المعلم (يتبع المدة المحتسبة)
  var rev = function (l) { return cmOf(l) / 60 * l.p; }; // رسوم الطالب = المدة المحتسبة × سعر الطالب (الحضور + الغياب المحتسب)
  // yyyy-mm-dd + days (بالتقويم، بلا مشاكل المنطقة الزمنية)
  var shiftDate = function (d, n) {
    var t = new Date(d + "T12:00:00Z");
    t.setUTCDate(t.getUTCDate() + n);
    return t.toISOString().slice(0, 10);
  };
  // نافذة التاريخ المسموحة للمعلم: آخر 35 يومًا حتى غدٍ (المشرف مستثنى في الواجهة والقاعدة)
  var dateOk = function (d, today) {
    return /^\d{4}-\d{2}-\d{2}$/.test(d || "") && d >= shiftDate(today, -35) && d <= shiftDate(today, 1);
  };
  // الساعات بالدقائق الدقيقة (س + د) بلا تقريب عشري، فيتطابق مجموع الصفوف مع الإجمالي
  var fhm = function (h) {
    var m = Math.round(h * 60), hh = Math.floor(m / 60), mm = m % 60;
    return m === 0 ? "0 د" : (hh ? hh + " س" : "") + (hh && mm ? " " : "") + (mm ? mm + " د" : "");
  };
  var api = { fhm: fhm, f2: f2, f4: f4, fh: fh, esc: esc, cmOf: cmOf, hrs: hrs, wage: wage, rev: rev, shiftDate: shiftDate, dateOk: dateOk };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.Calc = api;
})(typeof window !== "undefined" ? window : globalThis);
