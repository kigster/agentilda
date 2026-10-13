import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import type { Board } from "./types";
import { fetchBoard, isFixtureMode, loadFixtureBoard } from "./client";
import { openStream, type ConnectionState } from "./events";
import { BOARD_KEY } from "./queryClient";
import { replies } from "./replies";

export type { ConnectionState } from "./events";

export interface BoardState {
  board: Board | undefined;
  /** The first GET /api/board has not answered yet. */
  isLoading: boolean;
  error: Error | null;
  connection: ConnectionState;
  /** True under `?fixture`: the board is the sample file and nothing is live. */
  fixture: boolean;
}

/**
 * The page's whole state. TanStack Query holds the Board, first from `GET /api/board`, then from every `event: board`
 * on the stream; replies on the stream go to the reply bus, where useSendCommand waits for them.
 *
 * Call it once, at the top of the page: each call opens its own stream.
 */
export function useBoard(): BoardState {
  const fixture = isFixtureMode();
  const client = useQueryClient();
  const [connection, setConnection] = useState<ConnectionState>(fixture ? "live" : "reconnecting");
  const query = useQuery({ queryKey: BOARD_KEY, queryFn: fixture ? () => Promise.resolve(loadFixtureBoard()) : fetchBoard });

  useEffect(() => {
    if (fixture) return;
    return openStream({
      onBoard: board => client.setQueryData(BOARD_KEY, board),
      onReply: reply => replies.deliver(reply),
      onState: setConnection,
      onReconnect: () => void client.refetchQueries({ queryKey: BOARD_KEY }),
    });
  }, [client, fixture]);

  return { board: query.data, isLoading: query.isPending, error: query.error, connection, fixture };
}
