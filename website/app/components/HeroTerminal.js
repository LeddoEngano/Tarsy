"use client";

import { useState, useEffect, memo } from "react";
import { motion, AnimatePresence } from "framer-motion";

const sequences = [
  [
    { text: '$ claude "fix the auth bug"', style: "text-cream" },
    { text: "", style: "" },
    { text: "  Scanning codebase...", style: "text-taupe" },
    { text: "  Found issue in src/auth/session.ts:47", style: "text-taupe" },
    { text: "  Applying fix...", style: "text-taupe" },
    { text: "", style: "" },
    { text: "  + Fixed null check in validateToken()", style: "text-moss" },
    { text: "  + Added test coverage", style: "text-moss" },
    { text: "  + All 128 tests passing", style: "text-moss" },
  ],
  [
    { text: "$ tarsy connect --relay", style: "text-cream" },
    { text: "", style: "" },
    { text: "  Establishing secure tunnel...", style: "text-taupe" },
    { text: "  E2E encryption active", style: "text-moss" },
    { text: "  Streaming at 30fps / 6Mbps", style: "text-taupe" },
    { text: "", style: "" },
    { text: "  + Connected to MacBook Pro", style: "text-moss" },
    { text: "  + Ready for remote dev", style: "text-moss" },
  ],
  [
    { text: '$ aider "add dark mode toggle"', style: "text-cream" },
    { text: "", style: "" },
    { text: "  Reading project structure...", style: "text-taupe" },
    { text: "  Editing src/components/Theme.tsx", style: "text-taupe" },
    { text: "  Editing src/styles/globals.css", style: "text-taupe" },
    { text: "", style: "" },
    { text: "  + Theme provider implemented", style: "text-moss" },
    { text: "  + CSS variables configured", style: "text-moss" },
    { text: "  + 12 files updated", style: "text-moss" },
  ],
];

function HeroTerminal() {
  const [seqIndex, setSeqIndex] = useState(0);
  const [lineCount, setLineCount] = useState(0);

  const currentSeq = sequences[seqIndex];

  useEffect(() => {
    if (lineCount >= currentSeq.length) {
      const timeout = setTimeout(() => {
        setSeqIndex((s) => (s + 1) % sequences.length);
        setLineCount(0);
      }, 3000);
      return () => clearTimeout(timeout);
    }
    const delay = currentSeq[lineCount]?.text === "" ? 200 : 350;
    const timeout = setTimeout(() => setLineCount((c) => c + 1), delay);
    return () => clearTimeout(timeout);
  }, [lineCount, seqIndex, currentSeq]);

  return (
    <div className="relative">
      <div className="absolute -inset-6 bg-amber/[0.03] rounded-3xl blur-2xl" />
      <div className="relative bg-surface-raised border border-surface-overlay/60 rounded-2xl overflow-hidden shadow-2xl shadow-amber/[0.04]">
        <div className="flex items-center gap-2 px-5 py-3.5 border-b border-surface-overlay/50">
          <div className="w-2.5 h-2.5 rounded-full bg-terracotta/50" />
          <div className="w-2.5 h-2.5 rounded-full bg-amber/50" />
          <div className="w-2.5 h-2.5 rounded-full bg-moss/50" />
          <span className="ml-3 text-[11px] text-taupe/40 select-none">
            ~/my-project
          </span>
        </div>
        <div className="p-6 min-h-[300px]">
          <AnimatePresence mode="wait">
            <motion.div
              key={seqIndex}
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.3 }}
            >
              {currentSeq.slice(0, lineCount).map((line, i) => (
                <motion.div
                  key={i}
                  initial={{ opacity: 0, x: -6 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ duration: 0.25 }}
                  className={`${line.style} text-[13px] leading-7`}
                >
                  {line.text || "\u00A0"}
                </motion.div>
              ))}
            </motion.div>
          </AnimatePresence>
          {lineCount < currentSeq.length && (
            <motion.span
              className="inline-block w-2 h-4 bg-amber/70 mt-1"
              animate={{ opacity: [1, 0] }}
              transition={{
                duration: 0.8,
                repeat: Infinity,
                repeatType: "reverse",
              }}
            />
          )}
        </div>
      </div>
    </div>
  );
}

export default memo(HeroTerminal);
