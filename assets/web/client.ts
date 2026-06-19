import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { Editor } from "./hooks/editor";

interface EditorElement extends HTMLElement {
  _monacoEditor?: { getValue(): string };
}

function getEditorValue(): string | null {
  const el = document.querySelector("#editor") as EditorElement | null;
  return el?._monacoEditor?.getValue() ?? null;
}

const RunButton = {
  mounted(this: {
    el: HTMLElement;
    pushEvent(event: string, payload: Record<string, unknown>): void;
  }) {
    this.el.addEventListener("click", () => {
      const query = getEditorValue();
      if (query != null) this.pushEvent("run", { query });
    });
  },
};

const FormatButton = {
  mounted(this: {
    el: HTMLElement;
    pushEvent(event: string, payload: Record<string, unknown>): void;
  }) {
    this.el.addEventListener("click", () => {
      const query = getEditorValue();
      if (query != null) this.pushEvent("format", { query });
    });
  },
};

const Hooks = { Editor, RunButton, FormatButton };
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") ?? "";
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});
liveSocket.connect();

Object.assign(window, { liveSocket });
