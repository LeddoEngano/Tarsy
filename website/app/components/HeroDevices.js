"use client";

import { memo } from "react";
import { motion } from "framer-motion";

function HeroDevices() {
  return (
    <div className="relative w-full max-w-[520px] ml-auto pl-12 pb-20">
      {/* Ambient glow */}
      <div className="absolute -inset-6 bg-amber/[0.02] rounded-3xl blur-2xl" />

      {/* MacBook */}
      <motion.div
        className="relative"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.7, ease: [0.16, 1, 0.3, 1] }}
      >
        {/* Screen bezel */}
        <div className="bg-[#1a1a1a] rounded-xl overflow-hidden border border-surface-overlay/60 shadow-2xl shadow-black/30">
          {/* Camera dot */}
          <div className="flex justify-center py-1.5">
            <div className="w-1.5 h-1.5 rounded-full bg-[#0a0a0a]/80" />
          </div>
          {/* Screen area */}
          <div className="mx-1.5 mb-1.5 rounded-lg overflow-hidden bg-surface aspect-[16/11] relative">
            <video
              src="https://xtblbghhlkroskzljqcl.supabase.co/storage/v1/object/public/website-media/mac.mp4"
              autoPlay
              loop
              muted
              playsInline
              className="w-full h-full object-cover relative z-[1]"
            />
            {/* Placeholder when no video */}
            <div className="absolute inset-0 flex flex-col items-center justify-center gap-2">
              <div className="w-8 h-8 rounded-lg border border-surface-overlay/40 flex items-center justify-center">
                <svg
                  width="16"
                  height="16"
                  viewBox="0 0 16 16"
                  fill="none"
                  className="text-taupe/20"
                >
                  <path
                    d="M6 4l6 4-6 4V4z"
                    fill="currentColor"
                  />
                </svg>
              </div>
              <span className="text-[9px] text-taupe/20 uppercase tracking-widest">
                demo-mac.mp4
              </span>
            </div>
          </div>
        </div>
        {/* MacBook base */}
        <div className="mx-auto w-[80%] h-2.5 bg-[#1a1a1a] rounded-b-lg border-x border-b border-surface-overlay/50" />
        <div className="mx-auto w-[20%] h-1 bg-[#222]/60 rounded-b-sm" />
        <p className="text-center mt-3 text-[10px] text-taupe/30 uppercase tracking-[0.15em] select-none">
          executes on your mac
        </p>
      </motion.div>

      {/* iPhone */}
      <motion.div
        className="absolute bottom-2 left-0 z-10 w-[120px]"
        initial={{ opacity: 0, y: 30, scale: 0.95 }}
        animate={{ opacity: 1, y: 0, scale: 1 }}
        transition={{
          delay: 0.3,
          duration: 0.7,
          ease: [0.16, 1, 0.3, 1],
        }}
      >
        <div className="bg-[#111] border border-surface-overlay/70 rounded-[1.4rem] p-[3px] shadow-2xl shadow-black/50">
          {/* Screen area — full bleed, Dynamic Island floats on top */}
          <div className="rounded-[1.1rem] overflow-hidden bg-surface aspect-[9/20] relative">
            {/* Dynamic Island */}
            {/* Dynamic Island */}
            <div className="absolute top-0.5 left-0 right-0 flex justify-center z-10">
              <div className="w-12 h-3 bg-[#000] rounded-full" />
            </div>
            <video
              src="https://xtblbghhlkroskzljqcl.supabase.co/storage/v1/object/public/website-media/iphone.mp4"
              autoPlay
              loop
              muted
              playsInline
              className="w-full h-full object-cover object-bottom relative z-[1]"
            />
            {/* Placeholder when no video */}
            <div className="absolute inset-0 flex flex-col items-center justify-center gap-1.5">
              <div className="w-6 h-6 rounded-md border border-surface-overlay/40 flex items-center justify-center">
                <svg
                  width="12"
                  height="12"
                  viewBox="0 0 16 16"
                  fill="none"
                  className="text-taupe/20"
                >
                  <path
                    d="M6 4l6 4-6 4V4z"
                    fill="currentColor"
                  />
                </svg>
              </div>
              <span className="text-[7px] text-taupe/20 uppercase tracking-wider text-center leading-relaxed">
                demo-iphone.mp4
              </span>
            </div>
          </div>
        </div>
        <p className="text-center mt-2 text-[10px] text-taupe/30 uppercase tracking-[0.15em] select-none">
          you send from here
        </p>
      </motion.div>

      {/* Flow arrow: iPhone → Mac */}
      <motion.div
        className="absolute bottom-[85px] left-[110px] z-20"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 0.8, duration: 0.5 }}
      >
        <svg
          width="70"
          height="40"
          viewBox="0 0 70 40"
          fill="none"
          className="text-amber"
        >
          <path
            d="M4 32 C20 32, 30 8, 58 12"
            stroke="currentColor"
            strokeWidth="1"
            strokeDasharray="4 3"
            opacity="0.25"
          />
          <path
            d="M54 7 L60 12 L54 17"
            stroke="currentColor"
            strokeWidth="1"
            strokeLinecap="round"
            strokeLinejoin="round"
            opacity="0.25"
          />
        </svg>
      </motion.div>
    </div>
  );
}

export default memo(HeroDevices);
