//! Creates a synthetic vault for interface checks. Never point it at a real vault.
//!
//!   cargo run --example seed -- /tmp/pv-nsh-qa/vault
//!
//! Master password: `synthetic-preview-password`.
use serde_json::{json, Value};
use vault_core::VaultSession;

const PASSWORD: &str = "synthetic-preview-password";

fn main() {
    let dir = std::env::args().nth(1).expect("usage: seed <new vault directory>");
    let path = std::path::Path::new(&dir);
    assert!(!path.exists(), "refusing to touch an existing directory: {dir}");
    assert!(
        dir.starts_with("/tmp/") || dir.starts_with("/private/tmp/"),
        "synthetic vaults must live under /tmp"
    );
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let session = VaultSession::new(dir.clone()).unwrap();
    let run = |v: Value| session.command(v.to_string()).unwrap();
    run(json!({"op":"create","password":PASSWORD}));
    for name in ["家庭", "个人", "工作", "旅行"] {
        run(json!({"op":"category-add","name":name}));
    }
    let now = "2026-11-05T09:12:00Z";
    let base = |id: &str, kind: &str, title: &str| {
        json!({"id":id,"type":kind,"title":title,"username":"","note":"","tags":[],"noteFormat":"plain",
               "isDeleted":false,"isFavorite":false,"isPinned":false,"createdAt":now,"updatedAt":now})
    };
    let mut items = vec![];
    let mut a = base("a1", "password", "GitHub");
    a["username"] = json!("lin.dev@example.com");
    a["password"] = json!("gH7-vQ2-mZ9-pLx-demo");
    a["url"] = json!("https://github.com");
    a["secret"] = json!("JBSWY3DPEHPK3PXP");
    a["tags"] = json!(["开发", "2FA"]);
    a["isFavorite"] = json!(true);
    a["isPinned"] = json!(true);
    a["category"] = json!("工作");
    a["note"] = json!("组织管理员账号。恢复码位置见笔记「恢复信息存放位置」。");
    a["passwordHistory"] = json!([{"password":"old-demo-2025","changedAt":"2025-06-01T08:00:00Z"}]);
    items.push(a);
    for (id, title, user, pw, url) in [
        ("a2", "Apple ID", "lin@example.com", "demo-Apple-91x-long", "https://appleid.apple.com"),
        ("a3", "公司邮箱", "lin@company.example", "Spring2024", "https://mail.company.example"),
        ("a4", "Figma", "lin@company.example", "Spring2024", "https://figma.com"),
        ("a5", "家庭 Wi-Fi", "Home-Example", "demo-wifi-2026-home", ""),
    ] {
        let mut v = base(id, "password", title);
        v["username"] = json!(user);
        v["password"] = json!(pw);
        v["url"] = json!(url);
        items.push(v);
    }
    for (id, title, issuer, user, secret) in [
        ("c1", "Google", "Google", "lin@example.com", "GEZDGNBVGY3TQOJQ"),
        ("c2", "Cloudflare", "Cloudflare", "ops@example.com", "MFRGGZDFMZTWQ2LK"),
    ] {
        let mut v = base(id, "totp", title);
        v["issuer"] = json!(issuer);
        v["username"] = json!(user);
        v["secret"] = json!(secret);
        v["period"] = json!(30);
        items.push(v);
    }
    let mut card = base("w1", "creditCard", "示例信用卡");
    card["card"] = json!({"cardholder":"LIN XIAO","number":"4111 1111 1111 1111","expiryMonth":"08","expiryYear":"2029","securityCode":"123","brand":"Visa"});
    items.push(card);
    let mut ident = base("w2", "identity", "个人身份信息");
    ident["identity"] = json!({"lastName":"林","firstName":"晓","email":"lin@example.com","city":"示例市"});
    items.push(ident);
    let mut crypto = base("w3", "crypto", "以太坊钱包（示例）");
    crypto["network"] = json!("Ethereum");
    crypto["address"] = json!("0x8a3F1c9E2b7D4a6C0e5F9b1A2d3C4e5F6a7B8c9D");
    crypto["mnemonic"] = json!("orbit canvas meadow tiny verify lunar oyster bridge famous quote ribbon velvet");
    items.push(crypto);
    for (id, title, cat, body) in [
        ("n1", "家庭重要资料", "家庭", "紧急联系\n• 家庭邮箱：family@example.com\n• 物业服务：示例联系人\n\n重要文件\n• 证件与合同：书房文件柜 · 第二层"),
        ("n2", "旅行准备清单", "个人", "出发前\n☑ 护照有效期检查\n☐ 换汇\n☐ 充电宝与转换插头"),
        ("n3", "工作交接备忘", "工作", "交接时只分享条目链接，不直接复制密码到聊天工具。"),
    ] {
        let mut v = base(id, "secureNote", title);
        v["category"] = json!(cat);
        v["note"] = json!(body);
        items.push(v);
    }
    let mut trashed = base("t1", "password", "旧论坛账号");
    trashed["username"] = json!("lin_2015");
    trashed["isDeleted"] = json!(true);
    trashed["deletedAt"] = json!(now);
    items.push(trashed);
    for item in items {
        run(json!({"op":"save","item":item,"richNotes":true}));
    }
    run(json!({"op":"lock"}));
    println!("synthetic vault created at {dir} (password: {PASSWORD})");
}
