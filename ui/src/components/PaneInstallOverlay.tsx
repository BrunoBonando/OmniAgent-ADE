import "./PaneInstallOverlay.css";
import type { Agent } from "../state/agents";

interface PaneInstallOverlayProps {
  agent: Agent;
  status: 'in_progress' | 'failed';
}

function OmniAgentLogo() {
  // Simple SVG logo placeholder (200px)
  return (
    <svg
      width="200"
      height="200"
      viewBox="0 0 200 200"
      fill="none"
      aria-hidden
      className="pane-install-logo"
    >
      {/* Simplified OmniAgent logo: concentric circles with agent theme color */}
      <circle cx="100" cy="100" r="80" stroke="currentColor" strokeWidth="2" />
      <circle cx="100" cy="100" r="60" stroke="currentColor" strokeWidth="2" />
      <circle cx="100" cy="100" r="40" fill="currentColor" opacity="0.3" />
      <text
        x="100"
        y="105"
        textAnchor="middle"
        fontSize="24"
        fontWeight="bold"
        fill="currentColor"
      >
        OA
      </text>
    </svg>
  );
}

export default function PaneInstallOverlay({
  agent,
  status,
}: PaneInstallOverlayProps): JSX.Element {
  return (
    <div className="pane-install-overlay">
      {/* Dimmed backdrop over terminal */}
      <div className="pane-install-backdrop" />

      {/* Centered content */}
      <div className="pane-install-content">
        <OmniAgentLogo />
        <p className="pane-install-text">
          {status === 'in_progress' ? 'Installing…' : 'Installation failed'}
        </p>
        {status === 'failed' && (
          <p className="pane-install-hint">Check your network and try again</p>
        )}
      </div>
    </div>
  );
}
