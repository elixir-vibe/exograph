import * as monaco from "monaco-editor/esm/vs/editor/edcore.main.js";
import {
  conf as elixirConf,
  language as elixirLanguage,
} from "monaco-editor/esm/vs/basic-languages/elixir/elixir.js";

interface ViewHook {
  el: HTMLElement;
  pushEvent(
    event: string,
    payload: Record<string, unknown>,
    callback?: (reply: Record<string, unknown>) => void,
  ): void;
  handleEvent(event: string, callback: (payload: Record<string, unknown>) => void): void;
}

interface CompletionItem {
  label: string;
  kind: string;
  detail: string;
  insert_text: string;
}

interface DiagnosticMarker {
  message: string;
  line?: number;
  column?: number;
  end_line?: number;
  end_column?: number;
}

interface MonacoEditor {
  getValue(): string;
  setValue(value: string): void;
  focus(): void;
  getModel(): {
    getLineContent(n: number): string;
    getWordUntilPosition(p: Position): { startColumn: number; endColumn: number };
  } | null;
  getPosition(): Position | null;
  setPosition(position: Position): void;
  addCommand(keybinding: number, handler: () => void): void;
  dispose(): void;
}

interface Position {
  lineNumber: number;
  column: number;
}

interface MonacoModule {
  editor: {
    create(el: HTMLElement, opts: Record<string, unknown>): MonacoEditor;
    defineTheme(name: string, theme: Record<string, unknown>): void;
    setModelMarkers(model: unknown, owner: string, markers: unknown[]): void;
  };
  languages: {
    register(lang: { id: string }): void;
    getLanguages(): { id: string }[];
    setLanguageConfiguration(id: string, conf: unknown): void;
    setMonarchTokensProvider(id: string, lang: unknown): void;
    registerCompletionItemProvider(id: string, provider: unknown): { dispose(): void };
    CompletionItemKind: Record<string, number>;
  };
  Range: new (sl: number, sc: number, el: number, ec: number) => unknown;
  KeyMod: { CtrlCmd: number };
  KeyCode: { Enter: number };
  MarkerSeverity: { Error: number };
}

let completionProvider: { dispose(): void } | null = null;

const loadMonaco = (): Promise<MonacoModule> => Promise.resolve(monaco as MonacoModule);

const ELIXIR_LANGUAGE = "elixir";

function registerElixirLanguage(m: MonacoModule) {
  if (m.languages.getLanguages().some((l) => l.id === ELIXIR_LANGUAGE)) return;

  m.languages.register({ id: ELIXIR_LANGUAGE });
  m.languages.setLanguageConfiguration(ELIXIR_LANGUAGE, elixirConf);
  m.languages.setMonarchTokensProvider(ELIXIR_LANGUAGE, elixirLanguage);
}

function mapKind(m: MonacoModule, kind: string): number {
  const kinds = m.languages.CompletionItemKind;
  switch (kind) {
    case "module":
      return kinds.Module;
    case "function":
      return kinds.Function;
    case "field":
      return kinds.Field;
    case "variable":
      return kinds.Variable;
    default:
      return kinds.Text;
  }
}

interface EditorHook extends ViewHook {
  editor: MonacoEditor | null;
}

export const Editor = {
  editor: null as MonacoEditor | null,

  async mounted(this: EditorHook) {
    const container = this.el;
    const query = container.dataset.query || "";
    const m = await loadMonaco();

    registerElixirLanguage(m);

    m.editor.defineTheme("exograph", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "keyword", foreground: "c792ea" },
        { token: "type.identifier", foreground: "ffcb6b" },
        { token: "constant", foreground: "82aaff" },
        { token: "string", foreground: "c3e88d" },
        { token: "string.escape", foreground: "89ddff" },
        { token: "number", foreground: "f78c6c" },
        { token: "comment", foreground: "546e7a", fontStyle: "italic" },
        { token: "operator", foreground: "89ddff" },
        { token: "attribute", foreground: "f07178" },
        { token: "variable", foreground: "eeffff" },
        { token: "sigil", foreground: "c3e88d" },
        { token: "delimiter", foreground: "89ddff" },
        { token: "function.call", foreground: "82aaff" },
      ],
      colors: {
        "editor.background": "#09090b",
        "editor.foreground": "#f4f4f5",
        "editor.lineHighlightBackground": "#18181b",
        "editor.selectionBackground": "#27272a",
        "editorCursor.foreground": "#3b82f6",
        "editorWidget.background": "#18181b",
        "editorWidget.border": "#27272a",
        "editorSuggestWidget.background": "#18181b",
        "editorSuggestWidget.border": "#27272a",
        "editorSuggestWidget.selectedBackground": "#27272a",
        "list.hoverBackground": "#27272a",
      },
    });

    const editor = m.editor.create(container, {
      value: query,
      language: ELIXIR_LANGUAGE,
      theme: "exograph",
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: 13,
      lineHeight: 20,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      overviewRulerLanes: 0,
      renderLineHighlight: "line",
      padding: { top: 12, bottom: 12 },
      tabSize: 2,
      wordWrap: "on",
      automaticLayout: true,
      quickSuggestions: true,
      suggestOnTriggerCharacters: true,
    });

    editor.addCommand(m.KeyMod.CtrlCmd | m.KeyCode.Enter, () => {
      this.pushEvent("run", { query: editor.getValue() });
    });

    if (completionProvider) completionProvider.dispose();
    completionProvider = m.languages.registerCompletionItemProvider(ELIXIR_LANGUAGE, {
      triggerCharacters: [".", ":", '"', " "],
      provideCompletionItems: (model: ReturnType<MonacoEditor["getModel"]>, position: Position) => {
        if (!model) return { suggestions: [] };
        const line = model.getLineContent(position.lineNumber);
        const hint = line.slice(0, position.column - 1);
        const word = model.getWordUntilPosition(position);
        const range = new m.Range(
          position.lineNumber,
          word.startColumn,
          position.lineNumber,
          word.endColumn,
        );

        return new Promise((resolve) => {
          this.pushEvent("completion", { hint }, (reply) => {
            const items = (reply as unknown as { items: CompletionItem[] }).items || [];
            const suggestions = items.map((item) => ({
              label: item.label,
              kind: mapKind(m, item.kind),
              detail: item.detail,
              insertText: item.insert_text,
              range,
            }));
            resolve({ suggestions });
          });
        });
      },
    });

    this.handleEvent("set_editor_value", (payload) => {
      const { value } = payload as { value: string };
      editor.setValue(value);
      editor.focus();
    });

    this.handleEvent("update_url", (payload) => {
      const { q, page } = payload as { q: string; page?: number };
      const url = new URL(window.location.href);
      url.searchParams.set("q", q);
      if (page && page > 1) {
        url.searchParams.set("page", String(page));
      } else {
        url.searchParams.delete("page");
      }
      history.replaceState(null, "", url.toString());
    });

    this.handleEvent("scroll_to_line", (payload) => {
      const { line } = payload as { line: number };
      setTimeout(() => {
        const el = document.getElementById(`source-line-${line}`);
        if (el) el.scrollIntoView({ block: "center", behavior: "smooth" });
      }, 100);
    });

    this.handleEvent("set_diagnostics", (payload) => {
      const { markers } = payload as { markers: DiagnosticMarker[] };
      const model = editor.getModel();
      if (!model) return;
      m.editor.setModelMarkers(
        model,
        "exograph",
        markers.map((mk) => ({
          severity: m.MarkerSeverity.Error,
          message: mk.message,
          startLineNumber: mk.line || 1,
          startColumn: mk.column || 1,
          endLineNumber: mk.end_line || mk.line || 1,
          endColumn: mk.end_column || 1000,
        })),
      );
    });

    this.editor = editor;
    (container as HTMLElement & { _monacoEditor: MonacoEditor })._monacoEditor = editor;
  },

  destroyed(this: EditorHook) {
    if (this.editor) this.editor.dispose();
    if (completionProvider) {
      completionProvider.dispose();
      completionProvider = null;
    }
  },
};
