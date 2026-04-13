import { ImageResponse } from "next/og";

export const runtime = "edge";
export const alt = "Tarsy — Control your Mac dev environment from your iPhone";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          background: "#0a0a0a",
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          fontFamily: "system-ui, -apple-system, sans-serif",
          padding: "60px 80px",
        }}
      >
        {/* Top accent line */}
        <div
          style={{
            position: "absolute",
            top: 0,
            left: 0,
            right: 0,
            height: "4px",
            background: "linear-gradient(90deg, #d4a574, #c4956a, #b4855a)",
          }}
        />

        {/* Logo area */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: "16px",
            marginBottom: "40px",
          }}
        >
          <div
            style={{
              fontSize: "28px",
              color: "#d4a574",
              fontWeight: 600,
              letterSpacing: "-0.02em",
              textTransform: "uppercase",
            }}
          >
            TARSY
          </div>
        </div>

        {/* Main heading */}
        <div
          style={{
            fontSize: "56px",
            fontWeight: 800,
            color: "#ededed",
            textAlign: "center",
            lineHeight: 1.1,
            letterSpacing: "-0.03em",
            maxWidth: "900px",
          }}
        >
          Control your Mac dev
          <br />
          environment remotely
        </div>

        {/* Subheading */}
        <div
          style={{
            fontSize: "22px",
            color: "#888888",
            textAlign: "center",
            marginTop: "24px",
            maxWidth: "700px",
            lineHeight: 1.5,
          }}
        >
          Live screen streaming, AI coding agents, and end-to-end encrypted remote access — from your iPhone.
        </div>

        {/* Tags */}
        <div
          style={{
            display: "flex",
            gap: "12px",
            marginTop: "40px",
          }}
        >
          {["Claude Code", "Gemini CLI", "Codex", "Aider"].map((tag) => (
            <div
              key={tag}
              style={{
                padding: "8px 20px",
                borderRadius: "9999px",
                border: "1px solid rgba(212, 165, 116, 0.3)",
                color: "#d4a574",
                fontSize: "14px",
                fontWeight: 500,
              }}
            >
              {tag}
            </div>
          ))}
        </div>

        {/* Bottom info */}
        <div
          style={{
            position: "absolute",
            bottom: "30px",
            display: "flex",
            gap: "24px",
            color: "#555555",
            fontSize: "14px",
          }}
        >
          <span>iOS 17+ & macOS 14+</span>
          <span>·</span>
          <span>tarsy.dev</span>
        </div>
      </div>
    ),
    { ...size }
  );
}
