// Pure, framework-free onboarding phase state (Task 8.1) — same split as
// `state/sessions.ts`: a reducer with zero Tauri/React imports so the "what
// happens when" logic (when does the picker give way to a progress HUD, when
// does that give way to a completion banner) is unit-testable without
// mounting `FirstRun.tsx` or mocking `invoke()`. `FirstRun.tsx` dispatches
// `root_picked` right when it calls `rootsStartIngest`, then folds every
// ~2s `ingestionStatus()` poll (owned centrally by `App.tsx`, not this
// component — see its own module doc) through `status_polled`.
import type { IngestionStatus } from "../lib/tauri";

export type OnboardingPhase = "pick" | "ingesting" | "done";

export interface OnboardingState {
  phase: OnboardingPhase;
  /** Whether we've ever observed `status.running === true` since the last
   * `root_picked` — the only reliable way to tell "finished" apart from
   * "hasn't started yet" when polling a status snapshot that starts out
   * `{running: false}` before the background thread has run its first
   * update. */
  everRunning: boolean;
  status: IngestionStatus | null;
}

export const initialOnboardingState: OnboardingState = {
  phase: "pick",
  everRunning: false,
  status: null,
};

export type OnboardingAction =
  | { type: "root_picked" }
  | { type: "status_polled"; status: IngestionStatus }
  | { type: "retry" };

export function onboardingReducer(state: OnboardingState, action: OnboardingAction): OnboardingState {
  switch (action.type) {
    case "root_picked":
      return { phase: "ingesting", everRunning: false, status: null };

    case "status_polled": {
      if (state.phase !== "ingesting") return state;
      const everRunning = state.everRunning || action.status.running;
      if (everRunning && !action.status.running) {
        return { phase: "done", everRunning, status: action.status };
      }
      return { ...state, everRunning, status: action.status };
    }

    case "retry":
      return initialOnboardingState;

    default:
      return state;
  }
}
