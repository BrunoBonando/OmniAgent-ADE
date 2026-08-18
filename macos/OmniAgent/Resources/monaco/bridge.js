"use strict";
// The Swift side of this protocol is EditorWebView.swift — keep them in sync.
require.config({ paths: { vs: "vs" } });

// Deliberately NO `window.MonacoEnvironment = { getWorkerUrl: ... }`.
//
// Its absence is load-bearing, not an oversight. Defining `getWorkerUrl` makes
// Monaco call `new Worker("vs/base/worker/workerMain.js")` directly, and this
// page is loaded from `file://` — WebKit lets that Worker be *constructed* and
// then fails it asynchronously via `onerror`. Monaco's documented "falling back
// to the main thread" only triggers when construction throws *synchronously*,
// so the async failure leaves the editor worker permanently dead: no diff
// computation (the Changes tab silently shows two identical panes), no
// word-based suggestions, no link detection, and no error anywhere.
//
// With no override, Monaco's default AMD path wraps the worker in a Blob that
// `importScripts()` the absolute bundle URL, which WebKit does allow from a
// `file://` document. `EditorWebViewTests.testDiffEditorComputesChanges` is the
// regression test for exactly this — it fails if the override comes back.

let editor = null;
let diffEditor = null;
const models = new Map(); // path -> {model, savedVersionId, viewState, readOnly}
const snapshotTimers = new Map();
let diffModels = null; // {original, modified} — transient, disposed on hide

function post(message) { window.webkit.messageHandlers.editor.postMessage(message); }
function el(id) { return document.getElementById(id); }
function setBanner(text) {
  const banner = el("banner");
  banner.textContent = text || "";
  banner.style.display = text ? "block" : "none";
  document.body.classList.toggle("has-banner", !!text);
}

function showOnly(id) {
  for (const pane of ["editor", "diff", "changes", "message"]) {
    el(pane).style.display = pane === id ? "block" : "none";
  }
  // The banner belongs to the editor surface only; anything else showing
  // means it is describing a file that is no longer on screen.
  if (id !== "editor") setBanner("");
  if (id !== "diff" && diffModels) {
    diffModels.original.dispose();
    diffModels.modified.dispose();
    diffModels = null;
  }
}
function languageFor(path) {
  const dot = path.lastIndexOf(".");
  if (dot < 0) return "plaintext";
  const ext = path.slice(dot).toLowerCase();
  for (const lang of monaco.languages.getLanguages()) {
    if ((lang.extensions || []).some((e) => e.toLowerCase() === ext)) return lang.id;
  }
  return "plaintext";
}

const THEME = {
  base: "vs-dark",
  inherit: true,
  rules: [],
  colors: {
    "editor.background": "#0c0c0f",
    "editor.lineHighlightBackground": "#15151a",
    "editorLineNumber.foreground": "#4a4a55",
    "editorLineNumber.activeForeground": "#b0b0ba",
    "editorCursor.foreground": "#8b95ff",
    "editor.selectionBackground": "#2c2f52",
  },
};

require(["vs/editor/editor.main"], () => {
  monaco.editor.defineTheme("omniagent", THEME);
  editor = monaco.editor.create(el("editor"), {
    theme: "omniagent",
    automaticLayout: true,
    minimap: { enabled: false },
    wordBasedSuggestions: "currentDocument",
    fontSize: 12.5,
    fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
    scrollBeyondLastLine: false,
  });
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
    const model = editor.getModel();
    if (model) post({ type: "saveRequested", path: model.uri.path });
  });
  post({ type: "ready" });
});

window.omniagent = {
  // `show` defaults to true: opening a model is nearly always "put this on
  // screen". Crash recovery is the exception — it re-opens every model the
  // pane had, and showing each one in turn is n-1 wasted editor swaps and a
  // focus steal, all undone by the single `showModel` that follows.
  openModel(path, content, readOnly, show) {
    let entry = models.get(path);
    if (!entry) {
      const model = monaco.editor.createModel(content, undefined, monaco.Uri.file(path));
      entry = { model, savedVersionId: model.getAlternativeVersionId(), viewState: null, readOnly: !!readOnly };
      model.onDidChangeContent(() => {
        // Writes Swift itself just made are not user edits: `setContent`
        // raises this flag so the rebase of `savedVersionId` lands before
        // anyone can observe a dirty state that was never real.
        if (entry.suppressChanges) return;
        post({ type: "dirtyChanged", path, dirty: model.getAlternativeVersionId() !== entry.savedVersionId });
        clearTimeout(snapshotTimers.get(path));
        snapshotTimers.set(path, setTimeout(() => {
          post({ type: "contentSnapshot", path, content: model.getValue() });
        }, 2000));
      });
      models.set(path, entry);
    }
    if (show !== false) this.showModel(path);
  },
  // Swift replacing the buffer behind the user (a reload, or the file being
  // rewritten on disk). `onDidChangeContent` fires *synchronously* inside
  // `setValue`, so without the guard this would post `dirty:true` and arm a
  // 2 s snapshot before the `dirty:false` below — a visible tab flicker plus a
  // spurious snapshot of content Swift had just written itself.
  setContent(path, content) {
    const entry = models.get(path);
    if (!entry) return;
    entry.suppressChanges = true;
    try {
      entry.model.setValue(content);
      entry.savedVersionId = entry.model.getAlternativeVersionId();
    } finally {
      entry.suppressChanges = false;
    }
    clearTimeout(snapshotTimers.get(path));
    snapshotTimers.delete(path);
    post({ type: "dirtyChanged", path, dirty: false });
  },
  showModel(path) {
    const entry = models.get(path);
    if (!entry || !editor) return;
    showOnly("editor");
    const previous = editor.getModel();
    if (previous) {
      const prev = models.get(previous.uri.path);
      if (prev) prev.viewState = editor.saveViewState();
    }
    editor.setModel(entry.model);
    editor.updateOptions({ readOnly: entry.readOnly });
    if (entry.viewState) editor.restoreViewState(entry.viewState);
    editor.focus();
  },
  // `versionId` is the version whose text Swift actually wrote. If a
  // keystroke landed inside the getContent->write round trip the buffer has
  // moved on, and rebasing to the *current* version would mark that unsaved
  // edit clean — the tab would look saved and a later close would discard it
  // without asking. Refuse, and leave the tab dirty. Omitting the argument
  // keeps the old unconditional behaviour, for callers with nothing to race.
  markSaved(path, versionId) {
    const entry = models.get(path);
    if (!entry) return;
    const current = entry.model.getAlternativeVersionId();
    if (versionId !== undefined && versionId !== null && versionId !== current) return;
    entry.savedVersionId = current;
    post({ type: "dirtyChanged", path, dirty: false });
  },
  getContent(path) {
    const entry = models.get(path);
    if (!entry) return null;
    return { content: entry.model.getValue(), versionId: entry.model.getAlternativeVersionId() };
  },
  // Does the page still regard this buffer as saved? Swift cannot answer
  // that from its own dirty flag: `markSaved` posts nothing when it refuses
  // to rebase, and a posted message is not ordered against an
  // `evaluateJavaScript` reply — so "no news" is indistinguishable from "not
  // delivered yet". Asking the page is ordered, and therefore decidable.
  // A path with no model answers `true`: there is no buffer left to lose.
  isClean(path) {
    const entry = models.get(path);
    if (!entry) return true;
    return entry.model.getAlternativeVersionId() === entry.savedVersionId;
  },
  // Crash recovery: put an unsaved buffer back *without* rebasing
  // `savedVersionId`, so the rebuilt page agrees with Swift that the tab is
  // dirty against what is on disk. `setContent` above deliberately rebases
  // and would mark the restored edit clean — a later close would then discard
  // it with no prompt.
  restoreUnsaved(path, content) {
    const entry = models.get(path);
    if (!entry) return;
    entry.model.setValue(content);
  },
  closeModel(path) {
    const entry = models.get(path);
    if (!entry) return;
    clearTimeout(snapshotTimers.get(path));
    snapshotTimers.delete(path);
    // Disposing a model the editor still holds leaves it pointing at a dead
    // model; detach first.
    if (editor && editor.getModel() === entry.model) editor.setModel(null);
    entry.model.dispose();
    models.delete(path);
  },
  showDiff(path, original, modified) {
    showOnly("diff");
    if (!diffEditor) {
      diffEditor = monaco.editor.createDiffEditor(el("diff"), {
        theme: "omniagent",
        automaticLayout: true,
        readOnly: true,
        renderSideBySide: true,
        minimap: { enabled: false },
        fontSize: 12.5,
      });
    }
    if (diffModels) { diffModels.original.dispose(); diffModels.modified.dispose(); }
    const language = languageFor(path);
    diffModels = {
      original: monaco.editor.createModel(original, language),
      modified: monaco.editor.createModel(modified, language),
    };
    diffEditor.setModel(diffModels);
  },
  showChanges(files) {
    showOnly("changes");
    const container = el("changes");
    container.textContent = "";
    if (!files.length) {
      container.textContent = "No changes.";
      return;
    }
    for (const file of files) {
      const wrap = document.createElement("div");
      wrap.className = "file";
      // `appendFileDiff` finds its row by this, not by markup position.
      wrap.dataset.path = file.path;
      const row = document.createElement("div");
      row.className = "row";
      const badge = document.createElement("span");
      badge.className = "badge " + file.badge;
      badge.textContent = file.badge;
      const name = document.createElement("span");
      name.textContent = file.path;
      const open = document.createElement("span");
      open.className = "open-file";
      open.textContent = "open file";
      row.append(badge, name, open);
      const detail = document.createElement("pre");
      detail.style.display = "none";
      wrap.append(row, detail);
      row.addEventListener("click", (event) => {
        if (event.target === open) {
          post({ type: "changesOpen", path: file.path, target: "file" });
          return;
        }
        if (detail.style.display === "none") {
          detail.style.display = "block";
          if (!detail.dataset.loaded) post({ type: "requestFileDiff", path: file.path });
        } else {
          detail.style.display = "none";
        }
      });
      row.addEventListener("dblclick", () => post({ type: "changesOpen", path: file.path, target: "diff" }));
      container.append(wrap);
    }
  },
  appendFileDiff(path, text) {
    const container = el("changes");
    for (const wrap of container.querySelectorAll(".file")) {
      if (wrap.dataset.path !== path) continue;
      const detail = wrap.querySelector("pre");
      detail.dataset.loaded = "1";
      detail.textContent = "";
      for (const line of text.split("\n")) {
        const span = document.createElement("span");
        span.textContent = line + "\n";
        if (line.startsWith("+") && !line.startsWith("+++")) span.className = "add";
        else if (line.startsWith("-") && !line.startsWith("---")) span.className = "del";
        else if (line.startsWith("@@")) span.className = "hunk";
        detail.append(span);
      }
      return;
    }
  },
  // Spec 7: a text file too big to edit is opened read-only, and has to say
  // so — an editor that silently swallows keystrokes reads as broken.
  // `automaticLayout` re-lays Monaco out when the height changes under it.
  showBanner(text) {
    setBanner(text);
  },
  showMessage(text) {
    showOnly("message");
    el("message").textContent = text;
  },
  // Test hook: drives model.setValue WITHOUT resetting savedVersionId, so the
  // dirty transition a real keystroke produces is observable from XCTest.
  // `models` is closed over in this file, so Swift cannot reach it directly.
  typeForTesting(path, content) {
    this.restoreUnsaved(path, content);
  },
  // Test hook: the diff is computed asynchronously by the editor web worker
  // and has no bridge event of its own, so expose the change count. -1 means
  // "no diff editor yet", 0 means "not computed yet or genuinely identical".
  diffChangesForTesting() {
    return diffEditor ? (diffEditor.getLineChanges() || []).length : -1;
  },
};
