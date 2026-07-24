// Small in-app branding surface (the task explicitly asks for the real app
// icon to show up somewhere in-app besides the dock/title bar).
import logo from "../assets/omniagent-logo.png";

export default function AboutPanel({ onClose }: { onClose: () => void }) {
  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div className="about-panel" role="dialog" aria-label="About OmniAgent ADE" onMouseDown={(e) => e.stopPropagation()}>
        <img src={logo} alt="OmniAgent" className="about-logo" />
        <h2>OmniAgent ADE</h2>
        <p className="about-tagline">The knowledge graph is the operating system.</p>
        <p className="about-body">
          A local-first agentic development environment: parallel agent-CLI terminal sessions
          grouped per project, all feeding and fed by one fully local second brain.
        </p>
        <p className="about-version">v0.1.0 — dogfood build</p>
        <button className="about-close" onClick={onClose}>
          Close
        </button>
      </div>
    </div>
  );
}
