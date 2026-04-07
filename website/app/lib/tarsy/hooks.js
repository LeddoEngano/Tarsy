"use client";

import { useState, useEffect, useCallback } from "react";
import { createClient } from "../supabase/client";

/**
 * Fetch and subscribe to machines for the current user.
 * Returns { machines, selectedMachine, selectMachine, loading }
 */
export function useMachines() {
  const [machines, setMachines] = useState([]);
  const [selectedId, setSelectedId] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const supabase = createClient();
    let channel;

    async function load() {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) return;

      const { data } = await supabase
        .from("machines")
        .select("*")
        .eq("user_id", user.id)
        .order("created_at", { ascending: true });

      if (data) {
        setMachines(data);
        // Auto-select: prefer online, then first
        if (!selectedId) {
          const online = data.find((m) => m.status === "online");
          setSelectedId((online || data[0])?.id || null);
        }
      }
      setLoading(false);

      // Realtime subscription
      channel = supabase
        .channel("machines-realtime")
        .on("postgres_changes", {
          event: "*",
          schema: "public",
          table: "machines",
          filter: `user_id=eq.${user.id}`,
        }, (payload) => {
          if (payload.eventType === "UPDATE") {
            setMachines((prev) =>
              prev.map((m) => (m.id === payload.new.id ? payload.new : m))
            );
          } else if (payload.eventType === "INSERT") {
            setMachines((prev) => [...prev, payload.new]);
          } else if (payload.eventType === "DELETE") {
            setMachines((prev) => prev.filter((m) => m.id !== payload.old.id));
          }
        })
        .subscribe();
    }

    load();
    return () => {
      if (channel) supabase.removeChannel(channel);
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps — selectedId intentionally excluded to avoid re-subscribe loops

  const selectedMachine = machines.find((m) => m.id === selectedId) || null;

  return {
    machines,
    selectedMachine,
    selectMachine: setSelectedId,
    loading,
  };
}

/**
 * Fetch workspaces for a specific machine.
 */
export function useWorkspaces(machineId) {
  const [workspaces, setWorkspaces] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!machineId) {
      setWorkspaces([]);
      setLoading(false);
      return;
    }

    const supabase = createClient();
    let channel;

    async function load() {
      const { data } = await supabase
        .from("workspaces")
        .select("*")
        .eq("machine_id", machineId)
        .order("created_at", { ascending: true });

      if (data) setWorkspaces(data);
      setLoading(false);

      channel = supabase
        .channel(`workspaces-${machineId}`)
        .on("postgres_changes", {
          event: "*",
          schema: "public",
          table: "workspaces",
          filter: `machine_id=eq.${machineId}`,
        }, (payload) => {
          if (payload.eventType === "UPDATE") {
            setWorkspaces((prev) =>
              prev.map((w) => (w.id === payload.new.id ? payload.new : w))
            );
          } else if (payload.eventType === "INSERT") {
            setWorkspaces((prev) => [...prev, payload.new]);
          } else if (payload.eventType === "DELETE") {
            setWorkspaces((prev) => prev.filter((w) => w.id !== payload.old.id));
          }
        })
        .subscribe();
    }

    load();
    return () => {
      if (channel) supabase.removeChannel(channel);
    };
  }, [machineId]);

  return { workspaces, loading };
}

/**
 * Fetch active agent tasks for the current user.
 */
export function useActiveTasks() {
  const [tasks, setTasks] = useState([]);

  useEffect(() => {
    const supabase = createClient();
    let channel;

    async function load() {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) return;

      const { data } = await supabase
        .from("agent_tasks")
        .select("*")
        .eq("user_id", user.id)
        .in("status", ["running", "waiting"])
        .order("created_at", { ascending: false })
        .limit(20);

      if (data) setTasks(data);

      channel = supabase
        .channel("tasks-realtime")
        .on("postgres_changes", {
          event: "*",
          schema: "public",
          table: "agent_tasks",
          filter: `user_id=eq.${user.id}`,
        }, (payload) => {
          if (payload.eventType === "INSERT" || payload.eventType === "UPDATE") {
            const task = payload.new;
            setTasks((prev) => {
              const without = prev.filter((t) => t.id !== task.id);
              if (task.status === "running" || task.status === "waiting") {
                return [task, ...without];
              }
              return without; // Remove completed/error tasks
            });
          }
        })
        .subscribe();
    }

    load();
    return () => {
      if (channel) supabase.removeChannel(channel);
    };
  }, []);

  return tasks;
}

/**
 * Sign out and redirect to login.
 */
export function useSignOut() {
  return useCallback(async () => {
    const supabase = createClient();
    await supabase.auth.signOut();
    window.location.href = "/login";
  }, []);
}
