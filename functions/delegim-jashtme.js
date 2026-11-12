/* =====================================================================
   FAZA 2 · EDGE FUNCTION «delegim-jashtme» — faqja publike për të jashtmit
   DEPLOYUAR në Supabase (project ymetytjelrawsahpdisn, verify_jwt=false,
   version 4). Ky skedar është kopja burimore për referencë/rixhdrim.

   GET  ?token=…  → përmbledhja e dokumentit (vetëm nëse link-u është i
                    vlefshëm dhe i papërdorur)
   POST ?token=…  → emri + shënimi + firma (PNG data-URL) e të jashtmit
                    → link-u shënohet PËRDORUR + gjurmë në activity_log

   RLS anashkalohet VETËM me service role (SUPABASE_SERVICE_ROLE_KEY);
   anon nuk ka politika në external_links. Kujdes në këtë runtime:
   «new URL(req.url)» NUK punon — query-ja parse-ohet manualisht.
   ===================================================================== */
var CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "apikey, content-type"
};
function jjson(data, status) {
  return new Response(JSON.stringify(data), { status: status || 200, headers: Object.assign({}, CORS, { "content-type": "application/json" }) });
}
function qparam(rawUrl, name) {
  var qi = rawUrl.indexOf("?");
  if (qi < 0) return "";
  var parts = rawUrl.slice(qi + 1).split("&");
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=");
    var k = eq < 0 ? parts[i] : parts[i].slice(0, eq);
    var v = eq < 0 ? "" : parts[i].slice(eq + 1);
    try { if (decodeURIComponent(k.replace(/\+/g, " ")) === name) return decodeURIComponent(v.replace(/\+/g, " ")); } catch (e) {}
  }
  return "";
}

Deno.serve(async function (req) {
  try {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    var rawUrl = String(req.url);
    var token = qparam(rawUrl, "token").toLowerCase().replace(/[^a-f0-9]/g, "");
    if (token.length < 16) return jjson({ ok: false, gabim: "Mungon ose është i pavlefshëm token-i." }, 400);

    var SB = Deno.env.get("SUPABASE_URL") || "";
    var KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    var H = { apikey: KEY, Authorization: "Bearer " + KEY, "content-type": "application/json", "Accept": "application/json" };

    async function getLink() {
      var r = await fetch(SB + "/rest/v1/external_links?token=eq." + token + "&select=id,document_id,expires_at,used_at", { headers: H });
      var rows = await r.json();
      return Array.isArray(rows) && rows.length ? rows[0] : null;
    }

    if (req.method === "GET") {
      var L = await getLink();
      if (!L) return jjson({ ok: false, gabim: "Ky link s'ekziston ose është anuluar." }, 404);
      if (L.used_at) return jjson({ ok: false, gabim: "Ky link është përdorur tashmë." }, 410);
      if (new Date(L.expires_at).getTime() < Date.now()) return jjson({ ok: false, gabim: "Ky link ka skaduar (afati ishte 60 minuta). Kërkoni një link të re." }, 410);
      var dr = await fetch(SB + "/rest/v1/correspondence?id=eq." + L.document_id + "&select=protocol_no,subject,from_to,doc_date,doc_no,deleted_at", { headers: H });
      var docs = await dr.json();
      var d = Array.isArray(docs) && docs[0] ? docs[0] : null;
      if (!d || d.deleted_at) return jjson({ ok: false, gabim: "Dokumenti s'u gjet." }, 404);
      return jjson({ ok: true, doc: { proto: d.protocol_no, subject: d.subject, from: d.from_to, date: d.doc_date, docNo: d.doc_no }, expires_at: L.expires_at });
    }

    if (req.method === "POST") {
      var b = {};
      try { b = await req.json(); } catch (e2) { return jjson({ ok: false, gabim: "Kërkesë e pavlefshme." }, 400); }
      var name = String(b.name || "").trim().slice(0, 120);
      var note = String(b.note || "").trim().slice(0, 1000);
      var sig = String(b.signature || "");
      if (!name) return jjson({ ok: false, gabim: "Shkruani emrin tuaj." }, 400);
      if (!note) return jjson({ ok: false, gabim: "Shkruani shënimin tuaj." }, 400);
      if (!sig.startsWith("data:image/png;base64,") || sig.length > 500000) return jjson({ ok: false, gabim: "Vizatoni firmën tuaj." }, 400);
      var L2 = await getLink();
      if (!L2) return jjson({ ok: false, gabim: "Ky link s'ekziston." }, 404);
      if (L2.used_at) return jjson({ ok: false, gabim: "Ky link është përdorur tashmë." }, 410);
      if (new Date(L2.expires_at).getTime() < Date.now()) return jjson({ ok: false, gabim: "Ky link ka skaduar." }, 410);
      var u = await fetch(SB + "/rest/v1/external_links?id=eq." + L2.id, {
        method: "PATCH",
        headers: H,
        body: JSON.stringify({ used_at: new Date().toISOString(), name: name, note: note, signature_data: sig })
      });
      if (!u.ok) return jjson({ ok: false, gabim: "Ruajtja dështoi." }, 500);
      await fetch(SB + "/rest/v1/activity_log", {
        method: "POST",
        headers: H,
        body: JSON.stringify({ user_id: null, user_name: name + " (i jashtëm)", action: "link_jashtme_perdorur", document_id: L2.document_id, detail: note.slice(0, 200) })
      });
      return jjson({ ok: true });
    }

    return jjson({ ok: false, gabim: "Metodë e palejuar." }, 405);
  } catch (e) {
    return jjson({ ok: false, gabim: "Gabim i brendshëm: " + String(e && e.message ? e.message : e) }, 500);
  }
});
