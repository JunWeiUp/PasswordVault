import assert from "node:assert/strict";

export async function run(page, base = "http://127.0.0.1:4388") {
  const load = async () => {
    await page.goto(base + "/tests/fixtures/shadow-login.html");
    await page.waitForFunction(() =>
      qa.requests.some((request) => request.action === "login-pending"),
    );
  };
  const count = () =>
    page.evaluate(
      () =>
        qa.requests.filter((request) => request.action === "login-submitted")
          .length,
    );
  const seed = () =>
    page.evaluate(() => {
      const fields = [...qa.panel.querySelectorAll("fixture-field")].map(
        (host) => host.shadowRoot.querySelector("input"),
      );
      fields[0].value = "fictional@example.test";
      fields[1].value = "Synthetic-only-password";
    });
  await load();
  await seed();
  await page.click("button span");
  assert.equal(await count(), 1);
  assert.equal(
    await page.evaluate(() =>
      qa.requests.some(
        (request) =>
          request.username === "fictional@example.test" &&
          request.password === "Synthetic-only-password",
      ),
    ),
    true,
  );
  await load();
  await page.fill("input[name=username]", "fictional@example.test");
  await page.fill("input[name=password]", "Synthetic-only-password");
  await page.click("#outside");
  assert.equal(await count(), 1);
  assert.equal(
    await page.evaluate(() => !!document.querySelector("[popover]")),
    true,
  );
  await load();
  await page.evaluate(() => {
    qa.duplicate = true;
  });
  await seed();
  await page.click("button[type=button]");
  assert.equal(await count(), 1);
  assert.equal(
    await page.evaluate(() => !!document.querySelector("[popover]")),
    false,
  );
  await load();
  await page.evaluate(() => renderPanel());
  await seed();
  await page.focus("input[name=password]");
  await page.press("input[name=password]", "Enter");
  assert.equal(await count(), 1);
  for (const condition of [
    "hidden",
    "inert",
    "ambiguous",
    "otp",
    "empty",
    "disabled",
    "untrusted",
  ]) {
    await load();
    await seed();
    await page.evaluate((condition) => {
      const passwordHost = qa.panel.querySelectorAll("fixture-field")[1];
      const password = passwordHost.shadowRoot.querySelector("input");
      if (condition === "hidden") passwordHost.style.opacity = "0";
      if (condition === "inert") passwordHost.inert = true;
      if (condition === "ambiguous") password.after(password.cloneNode());
      if (condition === "otp") password.autocomplete = "one-time-code";
      if (condition === "empty") password.value = "";
      if (condition === "disabled")
        qa.panel
          .querySelector("fixture-action")
          .setAttribute("aria-disabled", "true");
      if (condition === "untrusted")
        qa.panel
          .querySelector("fixture-action")
          .shadowRoot.querySelector("button")
          .click();
    }, condition);
    if (condition === "disabled") {
      const point = await page.evaluate(() => {
        const rect = qa.panel
          .querySelector("fixture-action")
          .shadowRoot.querySelector("button")
          .getBoundingClientRect();
        return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
      });
      await page.mouse.click(point.x, point.y);
    } else if (condition !== "untrusted")
      await page.click("button[type=button]");
    assert.equal(await count(), 0, condition);
  }
  await load();
  await page.evaluate(() => {
    renderPanel({ form: true });
    const form = qa.panel;
    form.innerHTML =
      '<input name="username" value="fictional@example.test"><input name="password" type="password" value="Synthetic-only-password"><button>提交</button>';
  });
  await page.click("form button");
  assert.equal(await count(), 1);
  await load();
  await page.evaluate(() => {
    qa.panel
      .querySelectorAll("fixture-field")[1]
      .shadowRoot.querySelector("input").autocomplete = "new-password";
  });
  await page.fill("input[name=username]", "fictional@example.test");
  await page.fill("input[name=password]", "Synthetic-only-password");
  await page.click("#outside");
  assert.equal(await count(), 0);
  return [
    "shadow submit and paired values",
    "editing completion reminder",
    "duplicate notice suppression",
    "dynamic shadow Enter",
    "seven invalid/non-user actions rejected",
    "shadow native form submit",
    "new-password waits for submission",
  ];
}
