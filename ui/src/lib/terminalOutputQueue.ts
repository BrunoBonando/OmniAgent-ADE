type Write = (bytes: Uint8Array) => void;

export function createTerminalOutputQueue(write: Write) {
  let chunks: Uint8Array[] = [];
  let scheduled = false;
  let disposed = false;

  const flush = () => {
    scheduled = false;
    if (disposed || chunks.length === 0) return;
    const pending = chunks;
    chunks = [];
    const total = pending.reduce((size, chunk) => size + chunk.length, 0);
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of pending) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    write(bytes);
  };

  return {
    enqueue(bytes: Uint8Array) {
      if (disposed) return;
      chunks.push(bytes);
      if (scheduled) return;
      scheduled = true;
      if (typeof requestAnimationFrame === "function") {
        requestAnimationFrame(flush);
      } else {
        window.setTimeout(flush, 16);
      }
    },
    dispose() {
      disposed = true;
      chunks = [];
    },
  };
}
