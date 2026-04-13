"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import styles from "./contact.module.css";

const SUBJECT_OPTIONS = [
  { value: "general", label: "General Inquiry" },
  { value: "support", label: "Support" },
  { value: "bug", label: "Bug Report" },
  { value: "feature", label: "Feature Request" },
  { value: "business", label: "Business Inquiry" },
  { value: "other", label: "Other" },
];

export default function ContactForm() {
  const router = useRouter();
  const [subject, setSubject] = useState("general");
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [message, setMessage] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState("");
  const [showSuccess, setShowSuccess] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError("");

    if (!name.trim()) {
      setError("Name is required");
      return;
    }
    if (!email.trim()) {
      setError("Email is required");
      return;
    }
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email.trim())) {
      setError("Please enter a valid email address");
      return;
    }
    if (!message.trim()) {
      setError("Message is required");
      return;
    }

    setIsSubmitting(true);

    try {
      const response = await fetch("/api/contact", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          subject,
          name: name.trim(),
          email: email.trim(),
          message: message.trim(),
        }),
      });

      const result = await response.json();

      if (!response.ok || !result.success) {
        throw new Error(result.error || "Failed to send message");
      }

      setShowSuccess(true);
    } catch (err) {
      setError(err.message || "Something went wrong. Please try again.");
    } finally {
      setIsSubmitting(false);
    }
  };

  if (showSuccess) {
    return (
      <div className={styles.section}>
        <div className={styles.successContainer}>
          <div className={styles.successIcon}>
            <svg
              width="32"
              height="32"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <polyline points="20 6 9 17 4 12" />
            </svg>
          </div>
          <h1>Message Sent</h1>
          <p className={styles.subtitle}>
            Thank you for reaching out. We&apos;ll get back to you within 24
            hours.
          </p>
          <button
            className={styles.submitButton}
            onClick={() => router.push("/")}
          >
            Back to Home
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className={styles.section}>
      <h1>CONTACT US</h1>
      <p className={styles.subtitle}>
        Have questions, feedback, or need support? We&apos;d love to hear from
        you.
      </p>

      <form className={styles.form} onSubmit={handleSubmit}>
        {error && <div className={styles.error}>{error}</div>}

        <div className={styles.field}>
          <label className={styles.label} htmlFor="subject">
            Subject
          </label>
          <select
            id="subject"
            className={styles.select}
            value={subject}
            onChange={(e) => setSubject(e.target.value)}
            disabled={isSubmitting}
          >
            {SUBJECT_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
        </div>

        <div className={styles.field}>
          <label className={styles.label} htmlFor="name">
            Name
          </label>
          <input
            id="name"
            type="text"
            className={styles.input}
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Your name"
            disabled={isSubmitting}
          />
        </div>

        <div className={styles.field}>
          <label className={styles.label} htmlFor="email">
            Email
          </label>
          <input
            id="email"
            type="email"
            className={styles.input}
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="you@example.com"
            disabled={isSubmitting}
          />
        </div>

        <div className={styles.field}>
          <label className={styles.label} htmlFor="message">
            Message
          </label>
          <textarea
            id="message"
            className={styles.textarea}
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            placeholder="Tell us what's on your mind..."
            rows={5}
            disabled={isSubmitting}
          />
        </div>

        <button
          type="submit"
          className={styles.submitButton}
          disabled={isSubmitting}
        >
          {isSubmitting ? "Sending..." : "Send Message"}
        </button>
      </form>

      <div className={styles.altContact}>
        <p>
          Or email us directly at{" "}
          <a href="mailto:support@tarsy.dev">support@tarsy.dev</a>
        </p>
      </div>
    </div>
  );
}
