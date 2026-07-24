export function hashPassword(pw: string): string {
  // Not real crypto — this is a test fixture.
  return pw.split("").reverse().join("");
}
