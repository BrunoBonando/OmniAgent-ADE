// Fake sign-in + "getting to know you" gate — Bruno's own direction,
// verbatim: "let's skip the Import but let's Focus on getting to know the
// user after a login, but they can use it without login for now while in
// development. Login must be fake for now, just to test the workflow."
//
// This is a SEPARATE, EARLIER gate than `FirstRun.tsx`'s own "where do your
// projects live" onboarding — see `App.tsx`'s boot effect for exactly where
// the two compose (`needsAuthGate` resolves before `needsOnboarding` is
// ever allowed to render anything). `FirstRun.tsx` itself is untouched.
//
// Two phases, both here for the same reason `FirstRun.tsx` keeps its own
// phases in one file (`authGateState.ts`'s own doc): the transition logic
// is pure and unit-tested there, this component just renders whichever
// phase it's in.
//
// - "login": an honest placeholder sign-in — any non-blank email
//   "succeeds" instantly, no password, no network call, no fake loading
//   spinner (there's nothing to wait on). "Continue without signing in" is
//   laid out as an equally-sized, equally-legible second button, not a
//   buried text link — Bruno was explicit this is a dev-mode toggle, not a
//   paywall.
// - "personalize": shown only after the fake sign-in (never after skip) —
//   one single-select question, dev-tool-relevant options (not ChatGPT's
//   Marketing/Sales/HR categories), a Continue button, and its own skip.
//
// Resolving either path (skip-from-login, or personalize's
// answer/skip) calls `onResolved` exactly once with the final outcome;
// `App.tsx` owns turning that into the two persisted settings writes and
// flipping `needsAuthGate` off. This component never touches
// `settingsGet`/`settingsSet` itself — same ownership split
// `FirstRun.tsx` uses for `rootsStartIngest`/ingestion status.
import { useEffect, useReducer, useState } from "react";
import { authGateReducer, initialAuthGateState, PERSONA_OPTIONS, type AuthGateOutcome } from "./authGateState";

interface AuthGateProps {
  onResolved: (outcome: AuthGateOutcome) => void;
}

export default function AuthGate({ onResolved }: AuthGateProps) {
  const [state, dispatch] = useReducer(authGateReducer, initialAuthGateState);
  const [email, setEmail] = useState("");
  const [selectedPersona, setSelectedPersona] = useState<string | null>(null);

  useEffect(() => {
    if (state.phase === "resolved" && state.outcome) onResolved(state.outcome);
  }, [state.phase, state.outcome, onResolved]);

  if (state.phase === "resolved") return null;

  if (state.phase === "login") {
    const canContinue = email.trim().length > 0;
    return (
      <div className="overlay-backdrop">
        <div className="auth-gate-panel" role="dialog" aria-label="Sign in">
          <p className="auth-gate-eyebrow">&gt; sign in (placeholder)_</p>
          <h2 className="auth-gate-title">Sign in to OmniAgent</h2>
          <p className="auth-gate-body">
            This is a stand-in for real sign-in — any email works, nothing leaves this machine, and there&rsquo;s
            no account behind it yet. It&rsquo;s here so the flow can be reviewed before real auth ships.
          </p>
          <label className="auth-gate-field" htmlFor="auth-gate-email">
            Email
            <input
              id="auth-gate-email"
              className="auth-gate-input"
              type="email"
              placeholder="you@example.com"
              value={email}
              autoFocus
              onChange={(e) => setEmail(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && canContinue) dispatch({ type: "sign_in" });
              }}
            />
          </label>
          <div className="auth-gate-actions">
            <button
              className="auth-gate-cta"
              disabled={!canContinue}
              onClick={() => dispatch({ type: "sign_in" })}
            >
              Continue
            </button>
            <button className="auth-gate-secondary-cta" onClick={() => dispatch({ type: "skip_login" })}>
              Continue without signing in
            </button>
          </div>
        </div>
      </div>
    );
  }

  // phase === "personalize"
  return (
    <div className="overlay-backdrop">
      <div className="auth-gate-panel" role="dialog" aria-label="Tell us what you'll use OmniAgent for">
        <p className="auth-gate-eyebrow">&gt; getting to know you_</p>
        <h2 className="auth-gate-title">What best describes what you&rsquo;ll use OmniAgent for?</h2>
        <p className="auth-gate-body">
          Doesn&rsquo;t change anything today — just helps get the defaults right later.
        </p>
        <ul className="auth-gate-option-list">
          {PERSONA_OPTIONS.map((option) => (
            <li
              key={option.id}
              className={`auth-gate-option${option.id === selectedPersona ? " is-selected" : ""}`}
              onClick={() => setSelectedPersona(option.id)}
            >
              {option.label}
            </li>
          ))}
        </ul>
        <div className="auth-gate-actions">
          <button
            className="auth-gate-cta"
            disabled={!selectedPersona}
            onClick={() => selectedPersona && dispatch({ type: "answer_selected", persona: selectedPersona })}
          >
            Continue
          </button>
          <button className="auth-gate-skip" onClick={() => dispatch({ type: "skip_personalize" })}>
            Skip this question
          </button>
        </div>
      </div>
    </div>
  );
}
