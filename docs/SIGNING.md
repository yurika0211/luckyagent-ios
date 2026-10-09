# 签名：让 GitHub 打出能装到真机的包

没配签名时，CI 只出 **模拟器 .app**。这是正常的。iPhone 真机包必须用你自己的 Apple 证书，别人没法代签。

免费 Apple ID 只能签 7 天，而且 GitHub 云端跑不了这种签名。要在 Actions 里出包，需要 **Apple Developer Program（每年 99 美元）**。

## 你要准备的四个东西

1. 一张 **Apple Distribution** 证书，导出成 `.p12`，记一个导出密码。
2. 一个 **Ad Hoc** 或 **Development** 描述文件 `.mobileprovision`。Ad Hoc 要先登记 iPhone 的 UDID。
3. Team ID。developer.apple.com → Membership 里那串 10 位字符。
4. 描述文件的 UUID。一般不用手填，工作流会从文件里读。

Bundle ID 固定是 `com.luckyagent.ios`。证书、描述文件、App ID 必须用同一个。

## 怎么做证书

在一台 Mac 上：

1. 打开「钥匙串访问」→ 证书助理 → 从证书颁发机构请求证书。填邮箱，选「存储到磁盘」，得到 `CertificateSigningRequest.certSigningRequest`。
2. 打开 <https://developer.apple.com/account/resources/certificates/add>，选 **Apple Distribution**，上传 CSR，下载 `.cer`，双击装进钥匙串。
3. 钥匙串里展开这张证书，确认下面有私钥。右键证书 → 导出 → `.p12`，设一个密码。
4. Identifiers 里注册 App ID：`com.luckyagent.ios`。
5. Devices 里加上你的 iPhone UDID（设置 → 通用 → 关于本机，点型号那一行直到出现 UDID）。
6. Profiles 里新建 **Ad Hoc**，选这个 App ID、这张证书、这台设备，下载 `.mobileprovision`。

## 写进 GitHub Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret。

| Secret | 内容 |
|---|---|
| `IOS_CERTIFICATE_P12_BASE64` | `base64 -i cert.p12 \| pbcopy` 的结果 |
| `IOS_CERTIFICATE_PASSWORD` | 导出 p12 时设的密码 |
| `IOS_PROVISIONING_PROFILE_BASE64` | `base64 -i profile.mobileprovision` 的结果 |
| `IOS_TEAM_ID` | 10 位 Team ID |
| `IOS_KEYCHAIN_PASSWORD` | 随便设一串。CI 用它建临时钥匙串，不留在机器上 |

不要把 p12、描述文件、密码提交进 git。

## 触发

```bash
git tag v0.1.0
git push origin v0.1.0
```

只有 `v*` tag 才走签名 job。secrets 不齐时，这一步会跳过，不会把构建标红。模拟器包仍然在普通 push 的 artifact 里。

签名成功后，Release 页面会挂一个 `.ipa`。用 Apple Configurator、Xcode → Devices，或以前登记过的 Ad Hoc 安装方式装到那台 iPhone。

## 没有开发者账号时

用 Mac 打开这个仓库：

```bash
brew install xcodegen
xcodegen generate
open LuckyAgent.xcodeproj
```

Xcode 里选你的 Apple ID Team，Signing 设成 Automatic，直接 Run 到自己的手机。这种签名只在那台 Mac 上有效，过 7 天要重装。
