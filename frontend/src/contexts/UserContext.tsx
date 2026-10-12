"use client";

import { createContext, useContext, useState, useEffect, useCallback } from "react";
import axios from "axios";
import { authApi } from "@/lib/api";
import type { User } from "@/lib/types";

interface UserContextValue {
  user: User | null;
  loading: boolean;
  /** Session could not be loaded for a non-auth reason (network blip, 5xx). */
  error: boolean;
  refresh: () => Promise<void>;
}

const UserContext = createContext<UserContextValue>({
  user: null,
  loading: true,
  error: false,
  refresh: async () => {},
});

export function UserProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  const fetchUser = useCallback(async () => {
    setLoading(true);
    setError(false);
    try {
      const response = await authApi.me();
      setUser(response.data);
    } catch (err) {
      // A 401 is handled by the axios interceptor (client state reset + hard redirect
      // to /login). Navigating to /login here on OTHER failures would ping-pong
      // against the middleware forever (the presence cookie still says "logged
      // in", so /login bounces straight back to /dashboard). Surface a retryable
      // error state instead.
      if (!(axios.isAxiosError(err) && err.response?.status === 401)) {
        setError(true);
      }
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    // Via een microtask: fetchUser zet state, en dat synchroon doen in een
    // effect kost een extra rendercyclus voordat er iets op het scherm staat.
    queueMicrotask(fetchUser);
  }, [fetchUser]);

  return (
    <UserContext.Provider value={{ user, loading, error, refresh: fetchUser }}>
      {children}
    </UserContext.Provider>
  );
}

export function useUser(): UserContextValue {
  return useContext(UserContext);
}
