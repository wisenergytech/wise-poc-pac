// Supabase Auth for Shiny - client-side login
(function () {
  "use strict";

  var ns = window.__AUTH_NS__ || "";

  function initSupabase() {
    if (!window.__SUPABASE_URL__ || !window.__SUPABASE_KEY__) return null;
    return window.supabase.createClient(
      window.__SUPABASE_URL__,
      window.__SUPABASE_KEY__
    );
  }

  window.__wiseAuth = {
    signIn: async function (emailId, passwordId, errorId) {
      var emailEl = document.getElementById(emailId);
      var passwordEl = document.getElementById(passwordId);
      var errorEl = document.getElementById(errorId);

      var email = emailEl ? emailEl.value.trim() : "";
      var password = passwordEl ? passwordEl.value : "";

      if (!email || !password) {
        if (errorEl) errorEl.textContent = "Veuillez remplir tous les champs.";
        return;
      }

      if (errorEl) errorEl.textContent = "";

      var client = initSupabase();
      if (!client) {
        if (errorEl) errorEl.textContent = "Configuration Supabase manquante.";
        return;
      }

      var result = await client.auth.signInWithPassword({
        email: email,
        password: password,
      });

      if (result.error) {
        if (errorEl) errorEl.textContent = "Email ou mot de passe incorrect.";
        return;
      }

      // Send access token to Shiny server for verification
      var token = result.data.session.access_token;
      Shiny.setInputValue(ns + "access_token", token, { priority: "event" });
    },
  };

  // Handle server-side error messages
  Shiny.addCustomMessageHandler("auth-error", function (msg) {
    var el = document.getElementById(msg.id);
    if (el) el.textContent = msg.msg;
  });
})();
