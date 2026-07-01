import { JSONEditor, Mode } from "vanilla-jsoneditor"

const JsonEditor = {
  mounted() {
    const initialContent = JSON.parse(this.el.dataset.content)

    this.editor = new JSONEditor({
      target: this.el,
      props: {
        content: { json: initialContent },
        mode: Mode.text,
        mainMenuBar: true,
        statusBar: true,
        onChange: (updatedContent) => {
          this.currentContent = updatedContent
        }
      }
    })

    this.currentContent = { json: initialContent }

    // Listen for save trigger from the LiveView button
    this.el.addEventListener("json-editor:save", () => {
      const contentStr = this.getContent()
      if (contentStr !== null) {
        this.pushEvent("save", { content: contentStr })
      }
    })

    // Push content update from server (e.g. PubSub conflict)
    this.handleEvent("update-content", ({ content }) => {
      const parsed = JSON.parse(content)
      this.editor.set({ json: parsed })
      this.currentContent = { json: parsed }
    })
  },

  destroyed() {
    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
  },

  getContent() {
    if (this.currentContent.json !== undefined) {
      return JSON.stringify(this.currentContent.json)
    } else if (this.currentContent.text !== undefined) {
      return this.currentContent.text
    }
    return null
  }
}

export default JsonEditor
