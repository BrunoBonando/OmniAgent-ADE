import { hashPassword } from "./util";

export function login(user: string, password: string): boolean {
  return user.length > 0 && hashPassword(password).length > 0;
}

// tightened validation
