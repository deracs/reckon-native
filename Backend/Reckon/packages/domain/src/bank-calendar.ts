/** Shift a calendar date by whole UTC days, independent of daylight saving. */
export const addDays = (date: string, days: number): string => {
  const dt = new Date(`${date}T00:00:00.000Z`)
  dt.setUTCDate(dt.getUTCDate() + days)
  return dt.toISOString().slice(0, 10)
}

/** Shift a lookback date by calendar months using UTC month rollover. */
export const addMonths = (date: string, months: number): string => {
  const dt = new Date(`${date}T00:00:00.000Z`)
  dt.setUTCMonth(dt.getUTCMonth() + months)
  return dt.toISOString().slice(0, 10)
}
