<p align="center">
  <img src=".github/banner.svg" alt="YeelightBar" width="840">
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-0A0C0A?style=flat-square&logo=apple&logoColor=44D62C&labelColor=0A0C0A">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-44D62C?style=flat-square&logo=swift&logoColor=white&labelColor=0A0C0A">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-44D62C?style=flat-square&labelColor=0A0C0A">
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-44D62C?style=flat-square&labelColor=0A0C0A">
  <img alt="LAN only" src="https://img.shields.io/badge/cloud-none%20%C2%B7%20LAN%20only-44D62C?style=flat-square&labelColor=0A0C0A">
  <img alt="Stars" src="https://img.shields.io/github/stars/Keprun/YeelightBar?style=flat-square&labelColor=0A0C0A&color=44D62C">
</p>

[English](README.md) · [Русский](README.ru.md) · [中文](README.zh-CN.md) · [فارسی](README.fa.md) · [Español](README.es.md) · **العربية**

تطبيق macOS أصيل للتحكم في أجهزة **Yeelight** عبر الشبكة المحلية — صُمِّم خصيصًا لشريط الإضاءة **Yeelight Screen Light Bar Pro**
(`YLTD003`)، لكنه يشغّل أيضًا شرائط ومصابيح RGB العادية. البرنامج الرسمي يعمل على Windows فقط؛ أما هذا فهو بديل نظيف
وسريع مبني على SwiftUI، مع مزامنة الشاشة بإضاءة محيطية (ambilight)، وتفاعل مع الموسيقى، وتحكم جماعي بعدّة مصابيح.

> بلا سحابة، بلا حساب. كل شيء يجري عبر شبكتك المحلية.

## المزايا

- **تحكم كامل** — التشغيل، الضوء الأبيض الأمامي (السطوع + حرارة اللون)، RGB المحيطي، ومشاهد جاهزة.
- **تحكم جماعي / "مزج"** — اختر عدّة مصابيح وشغّلها معًا؛ كل مصباح يتحدث بلهجته الخاصة من البروتوكول
  (الشريط يملك قناة محيطية `bg` منفصلة، أما الشرائط فلا).
- **إضاءة محيطية متزامنة مع الشاشة** — يلتقط ScreenCaptureKit عيّنات من شاشتك ويبثّ اللون إلى القناة المحيطية للمصباح
  بمعدل ~20 هرتز عبر جلسة UDP.
  - **شاشة ومنطقة لكل مصباح**: في إعداد متعدد الشاشات، يمكن لكل مصباح أن يأخذ عيّناته من شاشة *مختلفة* ومن
    منطقة *مختلفة* منها (أعلى / أسفل / يسار / يمين / كاملة) — فمثلًا يأخذ الشريط الجزء العلوي من شاشتك الرئيسية،
    بينما يأخذ شريط أسفل المكتب الجزء السفلي من شاشة أخرى.
  - التقاط مستقل عن الدقة (يعمل على نسب 16:9 و4K والوضع العمودي والشاشات فائقة العرض 32:9 على حدٍّ سواء).
  - معاينة حيّة: لوحة على شكل شاشة لكل عرض تُظهر بالضبط أيّ منطقة يأخذ كل مصباح عيّناته منها، بلونها الحيّ.
- **التفاعل مع الموسيقى** — يلتقط صوت *النظام* (بلا ميكروفون)، ويقسّمه إلى جهير/متوسط/حادّ بمرشّحات IIR.
  - وضع **Beat** ينبض بالسطوع مع ضربة الباس؛ ووضع **Spectrum** يربط الجهير←أحمر / المتوسط←أخضر / الحادّ←أزرق.
- **واجهتان** — لوحة مدمجة في شريط القوائم للتعديلات السريعة، ونافذة كاملة قابلة لتغيير الحجم (`NavigationSplitView`)
  للإعداد.
- **متين على شبكة حقيقية** — اكتشاف تلقائي (SSDP + مسح نشط للشبكة الفرعية)، وإعادة اتصال عند تغيّر عنوان IP عبر DHCP،
  وتحكم متسلسل بحيث لا يُسقِط المصباح أيّ أمر قادم من اتصالات متزامنة.

## المتطلبات

- macOS 13 (Ventura) أو أحدث، على Apple Silicon أو Intel.
- جهاز (أو أجهزة) Yeelight مع تفعيل **LAN Control** (تطبيق Yeelight ← الجهاز ← *LAN Control*).
- إذن **تسجيل الشاشة** (System Settings ← Privacy & Security) لأوضاع مزامنة الشاشة والموسيقى.

## البناء والتشغيل

### Xcode
افتح `YeelightBar.xcodeproj` وشغّل مخطّط **YeelightBar** (⌘R). يُولَّد المشروع من `project.yml`
بواسطة [XcodeGen](https://github.com/yonaskolb/XcodeGen)؛ شغّل `xcodegen generate` بعد تعديل المواصفات.

### Swift Package Manager (بلا حاجة إلى Xcode)
```sh
swift build
./scripts/bundle.sh          # يجمّع build/YeelightBar.app ويوقّعه
open build/YeelightBar.app
```
ينشئ `scripts/setup-signing.sh` هوية توقيع شيفرة ذاتية ثابتة، حتى يبقى منح إذن تسجيل الشاشة قائمًا عبر
عمليات إعادة البناء (التوقيع المؤقت ad-hoc يتغيّر مع كل بناء وسيُعيد إطلاق طلب الإذن).

## `yeectl` — أداة سطر الأوامر

أداة CLI صغيرة لاختبار البروتوكول وبرمجته نصّيًا:

```sh
swift run yeectl discover                 # SSDP
swift run yeectl auto                      # SSDP، مع الرجوع إلى مسح نشط للشبكة الفرعية
swift run yeectl state   <ip>
swift run yeectl on|off  <ip>
swift run yeectl bright  <ip> <0-100>
swift run yeectl ct      <ip> <1700-6500>
swift run yeectl rgb     <ip> <hex e.g. FF8800>   # القناة المحيطية / bg
swift run yeectl rainbow <ip> [seconds]           # اختبار بثّ UDP بمعدل 20 هرتز
```

## البنية المعمارية

```
Sources/
  YeelightKit/            # مكتبة نقل فقط، بلا واجهة مستخدم
    Yeelight.swift        # تحكّم JSON عبر TCP 55443 + جلسة بثّ UDP 55444
    Discovery.swift       # اكتشاف SSDP عبر البثّ المتعدد
    Scan.swift            # مسح نشط للشبكة الفرعية + التحقق من عنوان IP يدوي
  yeectl/                 # CLI
  YeelightBarApp/         # تطبيق SwiftUI
    LampController.swift   # مخزن @MainActor: الاكتشاف، التحكم الجماعي، تنسيق المزامنة
    ScreenSyncEngine.swift # التقاط متعدد الشاشات ← لون لكل (شاشة، منطقة) ← توزيع عبر UDP
    MusicSyncEngine.swift  # التقاط صوت النظام ← beat/spectrum ← توزيع عبر UDP
    FullView.swift / MenuPanelView.swift
```

بروتوكول Yeelight عبر الشبكة المحلية (التحكم عبر TCP، ومصافحة البثّ عبر UDP، وقنوات الشريط الغريبة
`main_power`/`bg_power`) موثَّق في [`PROTOCOL.md`](PROTOCOL.md).

## ملاحظات حول Screen Light Bar Pro

يملك هذا المصباح قناتين مستقلتين — الأبيض الأمامي (`set_power` / `main_power`) و RGB المحيطي
(`bg_set_power` / `bg_set_rgb`) — فيمكنك تشغيل "المحيطي فقط". خاصية `power` لديه غير موثوقة (تبقى عند `on`
حتى عندما يكون الأمامي مطفأً)؛ لذا يقرأ التطبيق `main_power` بدلًا منها. الشرائط العادية تملك قناة واحدة وترفض
أمر `dev_toggle` الخاص بالشريط فقط، لذلك يُوجَّه التحكم حسب نوع كل جهاز.

## الترخيص

[MIT](LICENSE) — غير تابع لـ Yeelight / Xiaomi ولا معتمَد من قِبلهما.
