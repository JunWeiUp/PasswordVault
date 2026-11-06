//! User-initiated handoff to a preferred external terminal.
use nsh_core::prelude::*;
use std::{fs, io::Write, os::unix::fs::{DirBuilderExt, OpenOptionsExt}, path::{Path,PathBuf}, process::Command};
use serde_json::{json,Value};
/// Terminal preferences and explicit script launches (never exposed to AI).
#[module]
pub struct Scripts;
const TERMINALS: [(&str,&str,&str);4]=[("system","系统终端","com.apple.Terminal"),("iterm","iTerm2","com.googlecode.iterm2"),("ghostty","Ghostty","com.mitchellh.ghostty"),("tty7","tty7","com.github.tty7")];
fn identity(path:&Path)->Option<&'static str>{
 let out=Command::new("/usr/libexec/PlistBuddy").args(["-c","Print :CFBundleIdentifier"]).arg(path.join("Contents/Info.plist")).output().ok()?;
 if !out.status.success(){return None}let id=String::from_utf8_lossy(&out.stdout);
 TERMINALS.iter().find(|t|t.2==id.trim()).map(|t|t.0)
}
fn installed(id:&str)->Option<PathBuf>{
 if id=="system"{return Some(PathBuf::from("/System/Applications/Utilities/Terminal.app"))}
 let name=match id{"iterm"=>"iTerm.app","ghostty"=>"Ghostty.app","tty7"=>"tty7.app",_=>return None};
 [PathBuf::from("/Applications").join(name),PathBuf::from(std::env::var("HOME").ok()?).join("Applications").join(name)].into_iter().find(|p|identity(p)==Some(id))
}
fn preference_path(dir:&Path)->PathBuf{dir.join("terminal-preference.json")}
fn preference(dir:&Path)->Result<Value,String>{
 match fs::read(preference_path(dir)){Ok(bytes)=>serde_json::from_slice(&bytes).map_err(|_|"终端偏好损坏，请重新选择".into()),Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(json!({"id":"system"})),Err(_)=>Err("无法读取终端偏好".into())}
}
fn save_preference(dir:&Path,id:&str,path:&Path)->Result<(),String>{
 if !TERMINALS.iter().any(|t|t.0==id)||identity(path)!=Some(id){return Err("请选择 Terminal、iTerm2、Ghostty 或 tty7 应用".into())}
 fs::create_dir_all(dir).map_err(|_|"无法保存终端偏好")?;
 let tmp=dir.join(format!(".terminal-{}.tmp",uuid::Uuid::new_v4()));
 let result=(||{let mut f=fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp).map_err(|_|"无法保存终端偏好")?;f.write_all(json!({"id":id,"path":path}).to_string().as_bytes()).map_err(|_|"无法保存终端偏好")?;fs::rename(&tmp,preference_path(dir)).map_err(|_|"无法保存终端偏好")})();let _=fs::remove_file(tmp);result.map_err(str::to_owned)
}
fn resolve(dir:&Path)->Result<(&'static str,PathBuf),String>{
 let pref=preference(dir)?;let id=pref["id"].as_str().unwrap_or("system");let entry=TERMINALS.iter().find(|t|t.0==id).ok_or("请重新选择首选终端")?;
 let path=pref["path"].as_str().map(PathBuf::from).filter(|p|identity(p)==Some(id)).or_else(||installed(id)).ok_or("首选终端已移动或卸载，请重新选择")?;Ok((entry.0,path))
}
fn terminal_state(dir:&Path)->Result<String,String>{let pref=preference(dir)?;Ok(json!({"selected":pref["id"],"options":TERMINALS.iter().map(|(id,name,_)|{let available=installed(id).is_some()||(pref["id"]==*id&&pref["path"].as_str().is_some_and(|p|identity(Path::new(p))==Some(*id)));json!({"id":id,"name":name,"available":available})}).collect::<Vec<_>>()} ).to_string())}
fn quote(s:&str)->String{format!("'{}'",s.replace('\'',"'\"'\"'"))}
fn interpreter(name:&str,source:&str)->Result<&'static str,String>{
 let ext=name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();let mut command=match ext.as_str(){"sh"=>"/bin/sh","bash"=>"/bin/bash","zsh"|"command"=>"/bin/zsh","py"=>"/usr/bin/env python3","js"=>"/usr/bin/env node",_=>return Err("仅支持 Shell、Python 和 JavaScript 脚本".into())};
 if ["sh","bash","zsh","command"].contains(&ext.as_str()){command=match source.lines().next().unwrap_or("").trim(){"#!/bin/bash"|"#!/usr/bin/env bash"=>"/bin/bash","#!/bin/sh"|"#!/usr/bin/env sh"=>"/bin/sh","#!/bin/zsh"|"#!/usr/bin/env zsh"=>"/bin/zsh",_=>command};}Ok(command)
}
fn prepare(source:&str,name:&str)->Result<PathBuf,String>{
 if source.is_empty()||source.len()>262144||source.contains('\0'){return Err("脚本必须为非空文本，最多256 KiB".into())}let interpreter=interpreter(name,source)?;
 let dir=std::env::temp_dir().join(format!("passwordvault-run-{}",uuid::Uuid::new_v4()));
 fs::DirBuilder::new().mode(0o700).create(&dir).map_err(|_|"无法准备终端任务")?;
 let result=(||{let path=dir.join("source");let launcher=dir.join("run.command");
 let write=|path:&Path,text:&str,mode|->Result<(),String>{let mut f=fs::OpenOptions::new().write(true).create_new(true).mode(mode).open(path).map_err(|_|"无法准备终端任务")?;f.write_all(text.as_bytes()).map_err(|_|"无法准备终端任务".into())};
 write(&path,source,0o600)?;
 let cleanup=format!("/bin/rm -rf -- {}",quote(&dir.to_string_lossy()));
 let wrapper=format!("#!/bin/zsh\n# PasswordVault terminal handoff\ntrap {} EXIT\ntrap 'exit 130' INT\ntrap 'exit 143' TERM HUP\nexport PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"\ncd -- \"$HOME\" || exit 1\n{} {}\npv_result=$?\n{}\ntrap - EXIT\nprintf '\\n[PasswordVault] Exit: %s\\n' \"$pv_result\"\nexit \"$pv_result\"\n",quote(&cleanup),interpreter,quote(&path.to_string_lossy()),cleanup);
 write(&launcher,&wrapper,0o700)?;Ok(launcher)})();if result.is_err(){let _=fs::remove_dir_all(&dir);}result
}
fn tty_command(app:&Path)->Command {
 let mut cmd=Command::new(app.join("Contents/MacOS/tty7"));
 cmd.env_remove("TTY7_WS").env_remove("TTY7_PANE").env_remove("TTY7_CONFIG_DIR");cmd
}
fn launch_tty7(app:&Path,script:&Path)->Result<String,String>{
 if !app.join("Contents/MacOS/tty7").is_file(){return Err("tty7 缺少命令行组件，请更新 tty7".into())}
 let status=Command::new("/usr/bin/open").arg("-a").arg(app).status().map_err(|_|"无法打开 tty7")?;
 if !status.success(){return Err("无法打开 tty7".into())}
 let home=std::env::var("HOME").unwrap_or_else(|_|"/tmp".into());
 for _ in 0..10 {
  let out=tty_command(app).args(["--json","new",&home,"--open"]).output().map_err(|_|"无法创建 tty7 终端")?;
  if !out.status.success(){return Err("tty7 创建终端失败，请确认服务正常".into())}
  let info:Value=serde_json::from_slice(&out.stdout).map_err(|_|"tty7 返回格式不兼容")?;
  let id=info["id"].as_str().ok_or("tty7 缺少工作区标识")?.to_string();
  let cleanup=||{let _=tty_command(app).args(["ws","rm",&id]).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();};
  let Some(pane)=info["pane"].as_u64() else{cleanup();return Err("tty7 缺少终端标识".into())};
  if info["opened"]!=true{cleanup();std::thread::sleep(std::time::Duration::from_millis(200));continue}
  let _=tty_command(app).args(["ws","rename",&id,"PasswordVault"]).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
  let result=(||{
   let mut send=tty_command(app).args(["send",&format!("%{pane}"),"--stdin","--enter"]).stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn().map_err(|_|"无法发送到 tty7")?;
   let command=format!("/bin/zsh {}",quote(&script.to_string_lossy()));
   let wrote=send.stdin.take().unwrap().write_all(command.as_bytes());let status=send.wait().map_err(|_|"tty7 启动失败")?;
   if wrote.is_err()||!status.success(){return Err("tty7 启动失败")};Ok(())
  })();
  if let Err(e)=result{cleanup();return Err(e.into())}return Ok(id)
 }
 Err("tty7 窗口尚未就绪，请稍后重试".into())
}
fn launch(id:&str,app:&Path,script:&Path)->Result<(),String>{
 if id=="tty7"{return launch_tty7(app,script).map(|_|());}
 let mut cmd=Command::new("/usr/bin/open");
 if id=="ghostty"{cmd.args(["-n","-a"]).arg(app).args(["--args","-e","/bin/zsh"]).arg(script);}else{cmd.arg("-a").arg(app).arg(script);}
 let status=cmd.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status().map_err(|_|"无法打开终端")?;
 if status.success(){Ok(())}else{Err("无法打开首选终端，请重新选择".into())}
}
fn unlocked(session:&vault_core::VaultSession)->bool{session.command(r#"{"op":"status"}"#.into()).ok().and_then(|s|serde_json::from_str::<Value>(&s).ok()).is_some_and(|s|s["unlocked"]==true)}
#[module]
impl Scripts{
 /// Returns installed terminal choices and the persistent preference.
 pub async fn terminals(vault:Instance<crate::Vault>)->Result<String,String>{let dir=vault.with(|v|v.directory.clone());blocking(move||terminal_state(&dir)).await.map_err(|_|"Storage".to_string())?}
 /// Remembers an installed terminal for future launches.
 pub async fn select_terminal(vault:Instance<crate::Vault>,id:String)->Result<String,String>{let dir=vault.with(|v|v.directory.clone());blocking(move||{let path=installed(&id).ok_or("此终端尚未安装，请选择应用位置")?;save_preference(&dir,&id,&path)?;terminal_state(&dir)}).await.map_err(|_|"Storage".to_string())?}
 /// Selects a supported terminal bundle in a nonstandard location.
 pub async fn choose_terminal(vault:Instance<crate::Vault>)->Result<String,String>{let dir=vault.with(|v|v.directory.clone());blocking(move||{if let Some(path)=crate::files::panel("选择终端应用（Terminal / iTerm2 / Ghostty / tty7）".into(),None,vec!["app".into()])?{let path=PathBuf::from(path);let id=identity(&path).ok_or("请选择 Terminal、iTerm2、Ghostty 或 tty7 应用")?;save_preference(&dir,id,&path)?;}terminal_state(&dir)}).await.map_err(|_|"Storage".to_string())?}
 /// Opens the chosen terminal and executes source interactively; no in-app runner.
 pub async fn run(vault:Instance<crate::Vault>,name:String,source:String)->Result<String,String>{
 let (dir,session)=vault.with(|v|(v.directory.clone(),v.session.clone()));let session=session.ok_or("Locked")?;
 blocking(move||{let source=zeroize::Zeroizing::new(source);if !unlocked(&session){return Err("Locked".into())}let (id,app)=resolve(&dir)?;let script=prepare(&source,&name)?;if !unlocked(&session){let _=fs::remove_dir_all(script.parent().unwrap());return Err("Locked".into())}if let Err(e)=launch(id,&app,&script){let _=fs::remove_dir_all(script.parent().unwrap());return Err(e)}Ok(TERMINALS.iter().find(|t|t.0==id).unwrap().1.into())}).await.map_err(|_|"终端启动失败".to_string())?
 }
}
#[cfg(test)]mod tests{
 use super::*;use std::os::unix::fs::PermissionsExt;
 #[test]fn terminal_preference_persists_and_rejects_unknown(){let dir=std::env::temp_dir().join(format!("pv-terminal-test-{}",uuid::Uuid::new_v4()));assert_eq!(resolve(&dir).unwrap().0,"system");save_preference(&dir,"system",&installed("system").unwrap()).unwrap();assert_eq!(resolve(&dir).unwrap().0,"system");assert!(save_preference(&dir,"unknown",Path::new("/tmp/fake.app")).is_err());fs::remove_dir_all(dir).unwrap();}
 #[test]fn custom_terminal_is_remembered_without_silent_fallback(){
  let dir=std::env::temp_dir().join(format!("pv-terminal-pref-{}",uuid::Uuid::new_v4()));let app=dir.join("Custom iTerm.app");fs::create_dir_all(app.join("Contents")).unwrap();
  fs::write(app.join("Contents/Info.plist"),r#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.googlecode.iterm2</string></dict></plist>"#).unwrap();
  save_preference(&dir,"iterm",&app).unwrap();assert_eq!(resolve(&dir).unwrap(),("iterm",app.clone()));assert_eq!(preference(&dir).unwrap()["id"],"iterm");
  fs::remove_dir_all(app).unwrap();if installed("iterm").is_none(){assert!(resolve(&dir).is_err());}assert_eq!(preference(&dir).unwrap()["id"],"iterm");fs::remove_dir_all(dir).unwrap();
 }
 #[test]fn wrapper_preserves_source_and_cleans_on_failure(){let source="printf '%s' 'quotes $HOME `false`'; exit 7";let launcher=prepare(source,"strange';echo.sh").unwrap();let dir=launcher.parent().unwrap();assert_eq!(fs::read_to_string(dir.join("source")).unwrap(),source);assert_eq!(fs::metadata(dir).unwrap().permissions().mode()&0o777,0o700);assert_eq!(fs::metadata(dir.join("source")).unwrap().permissions().mode()&0o777,0o600);let out=Command::new("/bin/zsh").arg(&launcher).output().unwrap();assert_eq!(out.status.code(),Some(7));assert!(String::from_utf8_lossy(&out.stdout).contains("quotes $HOME `false`"));assert!(!dir.exists());}
 #[test]fn unsupported_and_interpreter_selection(){assert!(prepare("echo no","a.txt").is_err());assert!(prepare("","a.sh").is_err());assert_eq!(interpreter("a.command","#!/bin/bash\necho ok").unwrap(),"/bin/bash");assert_eq!(interpreter("a.py","print(1)").unwrap(),"/usr/bin/env python3");assert_eq!(quote("a'b"),"'a'\"'\"'b'");}
 #[test]
 #[ignore = "opens the system Terminal with a harmless synthetic command"]
 fn system_terminal_handoff_smoke(){
  let marker=std::env::temp_dir().join(format!("pv-terminal-marker-{}",uuid::Uuid::new_v4()));
  let source=format!("printf SYNTHETIC_TERMINAL_OK > {}",quote(&marker.to_string_lossy()));
  let launcher=prepare(&source,"test.sh").unwrap();launch("system",&installed("system").unwrap(),&launcher).unwrap();
  let deadline=std::time::Instant::now()+std::time::Duration::from_secs(15);
  while !marker.exists()&&std::time::Instant::now()<deadline {std::thread::sleep(std::time::Duration::from_millis(100));}
  let result=fs::read_to_string(&marker);let _=fs::remove_file(&marker);
  assert_eq!(result.unwrap(),"SYNTHETIC_TERMINAL_OK");
 }
 #[test]
 #[ignore = "opens tty7 and runs only a synthetic marker command"]
 fn tty7_handoff_smoke(){
  let app=installed("tty7").expect("tty7 installed");
  let marker=std::env::temp_dir().join(format!("pv-tty7-marker-{}",uuid::Uuid::new_v4()));
  let launcher=prepare(&format!("printf TTY7_TEST_OK > {}",quote(&marker.to_string_lossy())),"test.sh").unwrap();
  let workspace=launch_tty7(&app,&launcher).unwrap();
  let deadline=std::time::Instant::now()+std::time::Duration::from_secs(15);
  while !marker.exists()&&std::time::Instant::now()<deadline{std::thread::sleep(std::time::Duration::from_millis(100));}
  let result=fs::read_to_string(&marker);let _=fs::remove_file(&marker);
  let _=tty_command(&app).args(["ws","rm",&workspace]).status();
  assert_eq!(result.unwrap(),"TTY7_TEST_OK");
 }
 #[test]fn terminal_launch_failure_cleans_in_caller(){let launcher=prepare("printf ok","a.sh").unwrap();assert!(launch("system",Path::new("/nonexistent-terminal.app"),&launcher).is_err());fs::remove_dir_all(launcher.parent().unwrap()).unwrap();}
}
