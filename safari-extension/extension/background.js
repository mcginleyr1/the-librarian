chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.action === "save_clip") {
    handleClip(msg).then(sendResponse).catch(err => sendResponse({ status: "error", error: err.message }));
    return true; // async
  }
});

// The API token is a bearer credential: only send it over https, or plain http
// to this machine (local dev). Same check as popup.js.
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

async function handleClip({ mode, title, notebookId, tags, apiUrl, apiToken }) {
  const problem = apiUrlProblem(apiUrl);
  if (problem) throw new Error(problem);

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const sourceUrl = tab.url;
  const finalTitle = title || tab.title;

  let body = null;
  let isBase64 = false;

  switch (mode) {
    case "selection": {
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => window.getSelection().toString(),
      });
      body = results[0]?.result || "";
      break;
    }

    case "full_article": {
      // Inject Readability then extract
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        files: ["Readability.js"],
      });
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => {
          try {
            const article = new Readability(document.cloneNode(true)).parse();
            return article ? article.content : document.body.innerHTML;
          } catch (_) {
            return document.body.innerHTML;
          }
        },
      });
      body = results[0]?.result || "";
      break;
    }

    case "full_page": {
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => {
          const html = document.documentElement.outerHTML;
          // btoa with Unicode support
          return btoa(unescape(encodeURIComponent(html)));
        },
      });
      body = results[0]?.result || "";
      isBase64 = true;
      break;
    }

    case "screenshot": {
      const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
      body = dataUrl.split(",")[1]; // strip data:image/png;base64,
      isBase64 = true;
      break;
    }

    case "pdf": {
      // Fetch the current URL as binary (works for direct PDF URLs)
      const res = await fetch(sourceUrl);
      const buf = await res.arrayBuffer();
      const bytes = new Uint8Array(buf);
      let binary = "";
      for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
      body = btoa(binary);
      isBase64 = true;
      break;
    }

    default:
      throw new Error(`Unknown clip mode: ${mode}`);
  }

  const payload = {
    title: finalTitle,
    source_url: sourceUrl,
    clip_mode: mode,
    body,
    notebook_id: notebookId ? parseInt(notebookId) : null,
    tags,
  };

  const res = await fetch(`${apiUrl}/api/clips`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiToken || ""}`,
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({ status: "error" }));
    throw new Error(`API error ${res.status}: ${JSON.stringify(err.errors || err)}`);
  }

  return await res.json();
}
