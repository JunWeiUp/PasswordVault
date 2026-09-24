//! Creates a NEW, disposable fixture vault only. Never opens an existing vault.
use serde_json::json;
use vault_core::VaultSession;

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("Provide a new fixture directory");
    let option = std::env::args().nth(2);
    assert!(
        option.is_none() || option.as_deref() == Some("--english"),
        "Optional flag: --english"
    );
    let english = option.is_some();
    let session = VaultSession::new(path.clone()).expect("fixture directory available");
    session
        .command(json!({"op":"create","password":"Demo fixture only 2026!"}).to_string())
        .unwrap();
    let notes = if english {
        [
            ("Household essentials", "Family", "Keep everyday household information in one place.\n\n## Emergency contacts\n- Family email: family@example.com\n- Building services: Example contact\n\n## Important documents\n- IDs and contracts: Study cabinet, second shelf\n- Home insurance: Digital policy filed\n\n## Home network\n- Network name: Home-Example\n- Account credentials are stored in Passwords.\n\n## Backup reminder\nCheck encrypted backups monthly and update outdated details."),
            ("Devices and warranties", "Family", "Track device models, purchase details and warranties."),
            ("Travel checklist", "Personal", "Packing, documents and booking details for the next trip."),
            ("Account recovery reference", "Personal", "Keep recovery methods and storage locations together."),
            ("Subscriptions and renewals", "Work", "Track active services and upcoming renewal dates."),
            ("Work handover", "Work", "Account references, documents and handover notes."),
        ]
    } else {
        [("家庭重要资料","家庭","集中保存家庭常用信息，查找时更省心。\n\n## 紧急联系\n- 家庭邮箱：family@example.com\n- 物业服务：示例联系人\n\n## 重要文件\n- 证件与合同：书房文件柜 · 第二层\n- 房屋保险：电子保单已归档\n\n## 家庭网络\n- 网络名称：Home-Example\n- 账号与密码统一保存在「密码」中。\n\n## 备份提醒\n每月检查一次备份文件，更新过期信息。"),
        ("设备与保修信息","家庭","记录家中设备型号、购买信息与保修情况。"),
        ("旅行准备清单","个人","出行前的物品、证件和预订信息整理。"),
        ("恢复信息存放位置","个人","记录重要账号的恢复方式和存放位置。"),
        ("订阅与到期提醒","工作","管理各类订阅服务与到期时间。"),
        ("工作交接备忘","工作","整理工作交接的账号、文档和注意事项。")]
    };
    std::fs::write(
        std::path::Path::new(&path).join(".synthetic-fixture"),
        "PasswordVault synthetic fixture v2\n",
    )
    .unwrap();
    for (index, (title, category, note)) in notes.iter().enumerate() {
        let record = json!({"id":format!("note-{index}"),"type":"secureNote","title":title,"username":"","note":note,"category":category,"noteFormat":"markdown","isPinned":index==0,"updatedAt":format!("2020-01-0{}T00:00:00Z",6-index)});
        session
            .command(json!({"op":"save","item":record}).to_string())
            .unwrap();
    }
    let account_titles = if english {
        [
            "Family email",
            "Cloud storage",
            "Shopping",
            "Team workspace",
            "Example service",
        ]
    } else {
        ["家庭邮箱", "云盘", "购物账号", "工作协作", "示例服务"]
    };
    for (index, title) in account_titles.iter().enumerate() {
        session.command(json!({"op":"save","item":{"id":format!("password-{index}"),"type":"password","title":title,"username":"family@example.com","password":format!("Synthetic-only-{index}!"),"url":"https://mail.example.com","category":if english { "Family" } else { "家庭" },"note":if english { "For household notifications, separate from work." } else { "用于家庭服务通知，不用于工作。" },"tags":[if english { "Personal" } else { "个人" }]}}).to_string()).unwrap();
    }
    session.command(json!({"op":"save","item":{"id":"code-1","type":"totp","title":"Example authenticator","username":"family@example.com","secret":data_encoding::BASE32_NOPAD.encode(b"12345678901234567890"),"period":30}}).to_string()).unwrap();
    session.command(json!({"op":"settings","settings":{"language":if english { "en" } else { "zh" },"theme":"light","autoLockMinutes":30}}).to_string()).unwrap();
    session.command(json!({"op":"lock"}).to_string()).unwrap();
    println!("Created disposable synthetic fixture vault.");
}
