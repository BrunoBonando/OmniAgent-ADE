type Job = {
  run: () => void;
  cancelled: boolean;
};

const queue: Job[] = [];
let scheduled = false;

function scheduleNextFrame(callback: FrameRequestCallback): void {
  if (typeof requestAnimationFrame === "function") {
    requestAnimationFrame(callback);
  } else {
    window.setTimeout(() => callback(performance.now()), 16);
  }
}

function drainOneFrame(): void {
  scheduled = false;
  while (queue.length > 0) {
    const job = queue.shift()!;
    if (!job.cancelled) {
      job.run();
      break;
    }
  }
  if (queue.length > 0) {
    scheduled = true;
    scheduleNextFrame(drainOneFrame);
  }
}

export function scheduleTerminalJob(run: () => void): () => void {
  const job: Job = { run, cancelled: false };
  queue.push(job);
  if (!scheduled) {
    scheduled = true;
    scheduleNextFrame(drainOneFrame);
  }
  return () => {
    job.cancelled = true;
  };
}
