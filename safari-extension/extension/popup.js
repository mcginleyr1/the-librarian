let selectedMode = "selection";
// No default: each install points at its own Librarian (set in the popup).
let apiUrl = "";
let apiToken = "";

// The API token is a bearer credential: only send it over https, or plain http
// to this machine (local dev). Same check as background.js.
function apiUrlProblem(raw) {
  if (!raw) return "Set the API URL of your Librarian below";
  let url;
  try {
    url = new URL(raw);
  } catch (_) {
    return "API URL is not a valid URL";
  }
  const loopback = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol === "https:" || (url.protocol === "http:" && loopback)) return null;
  return "API URL must start with https:// (http:// only for localhost)";
}

function showStatus(kind, text) {
  const status = document.getElementById("status");
  status.className = kind ? `status ${kind}` : "status";
  status.textContent = text;
}

// --- Init ---

document.addEventListener("DOMContentLoaded", async () => {
  // Load saved API URL
  try {
    const stored = await chrome.storage.local.get(["apiUrl", "apiToken"]);
    apiUrl = stored.apiUrl || "";
    apiToken = stored.apiToken || "";
  } catch (_) {}
  document.getElementById("api-url").value = apiUrl;
  document.getElementById("api-token").value = apiToken;

  // Load current tab title
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab) document.getElementById("title").value = tab.title || "";
  } catch (_) {}

  // Load notebooks — never sending the token to an unsafe API URL
  const problem = apiUrlProblem(apiUrl);
  if (problem) {
    showStatus("error", `✗ ${problem}`);
  } else {
    try {
      const res = await fetch(`${apiUrl}/api/notebooks`, {
        headers: { Authorization: `Bearer ${apiToken}` },
      });
      if (res.ok) {
        const notebooks = await res.json();
        const sel = document.getElementById("notebook");
        notebooks.forEach(nb => {
          const opt = document.createElement("option");
          opt.value = nb.id;
          opt.textContent = nb.name;
          sel.appendChild(opt);
        });
      }
    } catch (_) {}
  }

  // Mode buttons
  document.querySelectorAll(".mode-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".mode-btn").forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      selectedMode = btn.dataset.mode;
    });
  });

  // Save API URL on change (only if it's safe to send the token to)
  document.getElementById("api-url").addEventListener("change", async e => {
    apiUrl = e.target.value.trim().replace(/\/$/, "");
    const problem = apiUrlProblem(apiUrl);
    if (problem) return showStatus("error", `✗ ${problem}`);
    showStatus(null, "");
    try { await chrome.storage.local.set({ apiUrl }); } catch (_) {}
  });

  // Save API token on change
  document.getElementById("api-token").addEventListener("change", async e => {
    apiToken = e.target.value.trim();
    try { await chrome.storage.local.set({ apiToken }); } catch (_) {}
  });

  // Save button
  document.getElementById("save-btn").addEventListener("click", saveClip);
});

// --- Save ---

async function saveClip() {
  const btn = document.getElementById("save-btn");

  btn.disabled = true;
  btn.textContent = "Saving...";
  showStatus(null, "");

  try {
    const problem = apiUrlProblem(apiUrl);
    if (problem) throw new Error(problem);

    const title = document.getElementById("title").value.trim();
    const notebookId = document.getElementById("notebook").value || null;
    const tags = document.getElementById("tags").value
      .split(",").map(t => t.trim()).filter(Boolean);

    const response = await chrome.runtime.sendMessage({
      action: "save_clip",
      mode: selectedMode,
      title,
      notebookId,
      tags,
      apiUrl,
      apiToken,
    });

    if (response && response.status === "ok") {
      showStatus("success", "✓ Saved to vault!");
      setTimeout(() => window.close(), 1200);
    } else {
      throw new Error(response?.error || "Unknown error");
    }
  } catch (err) {
    showStatus("error", `✗ ${err.message}`);
    btn.disabled = false;
    btn.textContent = "Save to Vault";
  }
}
