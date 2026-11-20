// A stand-in for Apple WeatherKit. Hourly wind: 5 m/s from 270°, gusting 7 m/s.
export function steadyWest(url: URL): Response {
  const start = Date.parse(url.searchParams.get("hourlyStart") ?? "");
  const end = Date.parse(url.searchParams.get("hourlyEnd") ?? "");
  const hours = [];
  for (let t = start; t < end; t += 3_600_000) {
    hours.push({
      forecastStart: new Date(t).toISOString(),
      windSpeed: 18,
      windDirection: 270,
      windGust: 25.2,
    });
  }
  return Response.json({ forecastHourly: { hours } });
}
