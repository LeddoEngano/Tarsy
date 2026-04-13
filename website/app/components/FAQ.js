"use client";

import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";

const faqs = [
  {
    q: "What is Tarsy?",
    a: "Tarsy is a remote development platform for the Apple ecosystem. It lets developers stream their Mac screen, control their Mac, and run AI coding agents (Claude Code, Gemini CLI, Codex CLI, Aider) remotely from their iPhone. All communication is end-to-end encrypted.",
  },
  {
    q: "How does Tarsy connect my iPhone to my Mac?",
    a: "Tarsy uses a smart-connect system that tries your local network first (LAN, port 8642) with a 3-second timeout, then automatically falls back to an encrypted relay server. No port forwarding or VPN is required. You can also force LAN-only or relay-only mode in settings.",
  },
  {
    q: "Is the screen streaming secure?",
    a: "Yes. All communication between your iPhone and Mac is end-to-end encrypted using TOFU (trust-on-first-use) key pinning. The relay server forwards encrypted packets without being able to read them. Screen frames are never stored or logged on any server.",
  },
  {
    q: "Which AI coding agents does Tarsy support?",
    a: "Tarsy supports Claude Code (Anthropic), Gemini CLI (Google), Codex CLI (OpenAI), Aider, and any custom CLI-based AI tool. Each agent runs as a local process on your Mac — Tarsy does not send your code to its own servers.",
  },
  {
    q: "What does Tarsy cost?",
    a: "Tarsy is free to use with 1 workspace. The Pro plan is $14.99 per month or $119.99 per year (approximately $9.99 per month), and includes unlimited workspaces and OpenClaw local AI access.",
  },
  {
    q: "What Mac and iPhone versions does Tarsy require?",
    a: "Tarsy requires macOS 14.0 or later (Apple Silicon and Intel) for the Mac companion app, and iOS 17.0 or later for the iPhone app.",
  },
  {
    q: "Does Tarsy store my screen recordings?",
    a: "No. Tarsy streams your screen in real time over an encrypted WebSocket connection. No frames are stored on the relay server, on Tarsy's infrastructure, or anywhere else. The stream exists only in transit between your Mac and your iPhone.",
  },
  {
    q: "Can I use Tarsy on a local network without internet?",
    a: "Yes. Tarsy supports direct LAN connections on port 8642. Both devices need to be on the same network. In LAN mode, no data leaves your local network — the relay server is not involved.",
  },
];

export default function FAQ() {
  const [openIndex, setOpenIndex] = useState(null);

  return (
    <div className="mt-12 space-y-2">
      {faqs.map((faq, i) => (
        <div
          key={i}
          className="border border-surface-overlay/30 rounded-xl overflow-hidden"
        >
          <button
            onClick={() => setOpenIndex(openIndex === i ? null : i)}
            className="w-full flex items-center justify-between px-6 py-5 text-left bg-surface-raised/50 hover:bg-surface-raised/80 transition-colors"
          >
            <span className="text-sm font-medium text-cream pr-4">
              {faq.q}
            </span>
            <svg
              width="16"
              height="16"
              viewBox="0 0 16 16"
              fill="none"
              className={`text-taupe/60 shrink-0 transition-transform duration-200 ${
                openIndex === i ? "rotate-180" : ""
              }`}
            >
              <path
                d="M4 6l4 4 4-4"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </button>
          <AnimatePresence>
            {openIndex === i && (
              <motion.div
                initial={{ height: 0 }}
                animate={{ height: "auto" }}
                exit={{ height: 0 }}
                transition={{ duration: 0.2, ease: "easeInOut" }}
                className="overflow-hidden"
              >
                <p className="px-6 py-4 text-xs text-taupe leading-relaxed border-t border-surface-overlay/20">
                  {faq.a}
                </p>
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      ))}
    </div>
  );
}
