import nodemailer from "nodemailer";
import { createShareService } from "./server.ts";

const env = process.env;
const transport = env.SMTP_HOST ? nodemailer.createTransport({
  host: env.SMTP_HOST, port: Number(env.SMTP_PORT ?? 587), secure: env.SMTP_SECURE === "true",
  requireTLS: true, auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASSWORD } : undefined,
  connectionTimeout: 10000, greetingTimeout: 10000, socketTimeout: 20000,
}) : undefined;
if (transport && !env.SMTP_FROM) throw new Error("Configure SMTP_FROM");
const { server } = createShareService({
  directory: env.SHARE_DATA_DIRECTORY ?? "./data",
  origin: env.SHARE_PUBLIC_ORIGIN ?? "http://127.0.0.1:8787",
  ownerTokens: (env.SHARE_OWNER_TOKENS ?? "").split(",").filter(Boolean),
  secret: env.SHARE_SERVICE_SECRET ?? "",
  allowedOrigins: (env.SHARE_ALLOWED_ORIGINS ?? "").split(",").map(value=>value.trim()).filter(value=>value && value!=="*"),
  sendCode: transport ? async (email, code) => {
    await transport.sendMail({ from: env.SMTP_FROM, to: email, subject: "PasswordVault sharing verification", text: `Your verification code is ${code}. It expires in ten minutes. If you did not request this, ignore this message.` });
  } : undefined,
});
server.listen(Number(env.PORT ?? 8787), env.HOST ?? "127.0.0.1", () => console.log("PasswordVault share service listening"));
for (const signal of ["SIGINT", "SIGTERM"] as const) process.on(signal, () => server.close());
