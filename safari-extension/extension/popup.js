const DEFAULT_API_URL = "https://librarian.tailf742b.ts.net";

let selectedMode = "selection";
let apiUrl = DEFAULT_API_URL;

// --- Init ---

document.addEventListener("DOMContentLoaded", async () => {
  // Load saved API URL
  try {
    const stored = await chrome.storage.local.get("apiUrl");
    apiUrl = stored.apiUrl || DEFAULT_API_URL;
  } catch (_) {
    apiUrl = DEFAULT_API_URL;
  }
  document.getElementById("api-url").value = apiUrl;

  // Load current tab title
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab) document.getElementById("title").value = tab.title || "";
  } catch (_) {}

  // Load notebooks
  try {
    const res = await fetch(`${apiUrl}/api/notebooks`);
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

  // Mode buttons
  document.querySelectorAll(".mode-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".mode-btn").forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      selectedMode = btn.dataset.mode;
    });
  });

  // Save API URL on change
  document.getElementById("api-url").addEventListener("change", async e => {
    apiUrl = e.target.value.trim().replace(/\/$/, "");
    try { await chrome.storage.local.set({ apiUrl }); } catch (_) {}
  });

  // Save button
  document.getElementById("save-btn").addEventListener("click", saveClip);
});

// --- Save ---

async function saveClip() {
  const btn = document.getElementById("save-btn");
  const status = document.getElementById("status");

  btn.disabled = true;
  btn.textContent = "Saving...";
  status.className = "status";
  status.textContent = "";

  try {
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
    });

    if (response && response.status === "ok") {
      status.className = "status success";
      status.textContent = "✓ Saved to vault!";
      setTimeout(() => window.close(), 1200);
    } else {
      throw new Error(response?.error || "Unknown error");
    }
  } catch (err) {
    status.className = "status error";
    status.textContent = `✗ ${err.message}`;
    btn.disabled = false;
    btn.textContent = "Save to Vault";
  }
}
