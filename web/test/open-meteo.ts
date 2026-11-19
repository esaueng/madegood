// A stand-in for Open-Meteo, so post-processing never reaches the network in tests.
// test/apple.ts routes requests for the Open-Meteo hosts lib/wind.ts uses here.

export const openMeteoRequests: URL[] = [];

type Handler = (url: URL) => Response | Promise<Response>;

/** Hourly wind for the requested dates: 5 m/s from 270°, gusting 7 m/s. */
export const steadyWest: Handler = (url) => {
  const start = Date.parse(`${url.searchParams.get("start_date")}T00:00:00Z`) / 1000;
  const end = Date.parse(`${url.searchParams.get("end_date")}T23:00:00Z`) / 1000;
  const time: number[] = [];
  for (let t = start; t <= end; t += 3600) time.push(t);
  return Response.json({
    hourly: {
      time,
      wind_speed_10m: time.map(() => 5),
      wind_direction_10m: time.map(() => 270),
      wind_gusts_10m: time.map(() => 7),
    },
  });
};

let handler: Handler = steadyWest;

/** Replaces the response for the rest of the test file; `steadyWest` restores the default. */
export function answerOpenMeteo(next: Handler) {
  handler = next;
}

export async function openMeteo(url: URL): Promise<Response> {
  openMeteoRequests.push(url);
  return handler(url);
}
