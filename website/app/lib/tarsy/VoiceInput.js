"use client";

import { useState, useRef, useCallback, useEffect } from "react";

const SUPPORTED_LANGUAGES = [
  { code: "en-US", name: "English" },
  { code: "pt-BR", name: "Portugues (BR)" },
  { code: "es-ES", name: "Espanol" },
  { code: "fr-FR", name: "Francais" },
  { code: "de-DE", name: "Deutsch" },
  { code: "it-IT", name: "Italiano" },
  { code: "ja-JP", name: "Japanese" },
  { code: "ko-KR", name: "Korean" },
  { code: "zh-CN", name: "Chinese" },
];

/**
 * Hook for voice input using Web Speech API.
 * Only works in Chrome/Edge.
 */
export function useVoiceInput() {
  const [isRecording, setIsRecording] = useState(false);
  const [transcription, setTranscription] = useState("");
  const [supported, setSupported] = useState(true);
  const [language, setLanguage] = useState("en-US");
  const recognitionRef = useRef(null);
  const committedRef = useRef("");
  const transcriptionRef = useRef("");

  useEffect(() => {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      setSupported(false);
    }
    // Load saved language
    const saved = localStorage.getItem("tarsy_voice_lang");
    if (saved) setLanguage(saved);
  }, []);

  const changeLanguage = useCallback((code) => {
    setLanguage(code);
    localStorage.setItem("tarsy_voice_lang", code);
  }, []);

  const startRecording = useCallback(() => {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) return;

    const recognition = new SpeechRecognition();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = language;

    recognition.onresult = (event) => {
      let partial = "";
      for (let i = event.resultIndex; i < event.results.length; i++) {
        partial += event.results[i][0].transcript;
      }
      const full = committedRef.current ? `${committedRef.current} ${partial}` : partial;
      setTranscription(full);
      transcriptionRef.current = full;
    };

    recognition.onend = () => {
      // Auto-restart if still recording
      if (recognitionRef.current) {
        committedRef.current = transcriptionRef.current;
        try { recognitionRef.current.start(); } catch { /* already started */ }
      }
    };

    recognition.onerror = () => {
      setIsRecording(false);
      recognitionRef.current = null;
    };

    recognitionRef.current = recognition;
    committedRef.current = "";
    setTranscription("");
    setIsRecording(true);
    recognition.start();
  }, [language]);

  const stopRecording = useCallback(() => {
    if (recognitionRef.current) {
      const ref = recognitionRef.current;
      recognitionRef.current = null; // Prevent auto-restart
      ref.stop();
    }
    setIsRecording(false);
  }, []);

  return {
    isRecording,
    transcription,
    supported,
    language,
    languages: SUPPORTED_LANGUAGES,
    changeLanguage,
    startRecording,
    stopRecording,
  };
}
