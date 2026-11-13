# macOS 性能：帧调度与局部重绘

本文记录 macOS 上播放 + 歌词页高频重绘的性能改动、验证方法与已知问题。Linux 侧不受本文改动影响；原有 Linux 局部重绘语义保持不变。

## 背景

GPUI 的渲染器每帧重绘整个窗口。上游 Linux 后端已接入场景损坏（`SceneDamage`）局部重绘，macOS 的 Metal 后端没有消费端，因此只要有一个像素变化（进度条、歌词高亮）就是整窗重绘。应用层原本还有一处放大：限帧的歌词/进度帧链按显示刷新自旋，30 FPS 目标在 100–120 Hz 屏幕上仍每秒唤醒 100–120 次。

本次改动分三层：

| 层 | 改动 | 位置 |
| --- | --- | --- |
| 应用 | macOS 默认帧率与截止点唤醒 | `crates/lyrune/src/settings.rs`、`app/animation.rs`、`app/lyrics_view.rs`、`app/progress_view.rs` |
| 渲染 | Metal 后端消费 `SceneDamage` | GPUI fork 分支（见下） |
| 绘制 | 经测量无收益，未改 | `app/lyrics_view.rs`（仅测量） |

## 1. 应用层：平台默认帧率与截止点唤醒

- macOS 默认 `lyric_scroll_frame_rate = Fps60`（其他平台仍为 `Display`），`progress_frame_rate = Fps30`（其他平台仍为 `Fps60`）。`lyric_highlight_frame_rate` 保持 `Fps30`。
- 歌词与进度的帧链在未到限帧截止点时不再申请显示帧，而是用后台定时器在截止点唤醒一次；到期的帧仍由 `on_next_frame` 采样，`frame_is_due` 的 deadline 累加语义、暂停/`reduce_motion` 行为和可取消性不变。

确定性测量（模拟显示帧 + 时钟推进，120 Hz 显示）：

| 指标 | 基线 | 改动后 |
| --- | --- | --- |
| 30 FPS 歌词每秒唤醒（120 个显示帧窗口） | 120 | 30 |
| 60 Hz 显示下每秒唤醒 | 60 | 30 |
| demand 模型绘制耗时/秒 | 1808 µs | 465 µs |
| 整秒主线程耗时（demand） | 2422 µs | 1029 µs |
| 暂停后 120 个显示帧内唤醒 | 120 | 0 |

注意：新默认值只对没有持久化帧率字段的配置生效。已有 `settings.json` 会保留用户此前的显式值，可在设置页的“动画帧率”里改成新默认。

## 2. 渲染层：Metal 局部重绘

GPUI fork 新增 macOS 后端对 `SceneDamage` 的消费：

- `MetalRenderer` 增加持久 `frame_texture` 与 `pending_damage` 累积，新增 `draw_with_damage`：`Full`/纹理失效走全量并 `Clear`；`Rects` 用 `Load` + 每个脏矩形的 scissor，只重放与脏矩形相交的 batch；`Unchanged` 在取 drawable 前直接返回。
- path 的中间纹理 encoder 同样按脏矩形 scissor，且没有任何 path 与脏矩形相交时整批跳过。
- 呈现改为 blending-disabled 的 1:1 copy pass 写入 drawable，避免为了 blit 关闭 `framebufferOnly`。
- `gpui_macos::Window` 实现 `PlatformWindow::draw_with_damage`（此前只有 `draw`，默认实现会退化为全量）。

依赖 pin：`sunstrikes/zed@2ea3ae243013d0a5698b13462a84dfd3c98a79d5`（`amtoaer/zed@a3e63a18` 之上一个 commit），来源说明见依赖仓库的 `LYRUNE-GPUI.md`。本仓库 `Cargo.toml` 的 `[patch.crates-io]` 与 `Cargo.lock` 已固定该 rev。

正确性与性能证据（离屏 Metal，`crates/gpui_apple/src/damage_tests.rs` / `damage_bench.rs`）：

- 18 个逐像素等价测试：先全量渲染 A，再按 damage 增量渲染 B，与独立全量渲染 B 逐像素 RGBA 比较，差异像素数必须为 0；覆盖 Rects / Unchanged / resize 失效 / 透明窗口 alpha / path / 连续 10 帧增量。
- bench（2400×1600 设备像素，1000 sprites + 3 paths，31 样本中位数）：全量 0.496 ms → 1 个脏矩形 0.059 ms（8.5×）、2 个 0.111 ms（4.5×）；未变化帧 0.053 ms（不取 drawable）。bench 的脏区只有窗口的 0.036%–0.071%，真实歌词帧的脏区更大，真机收益低于 8.5×。

真机端到端（同一首歌、同一窗口、前台播放 + 全屏歌词页、固定帧率配置，100 Hz 显示器，`ioreg` 整机 GPU 利用率，每轮 15–30 个 1 秒样本）：

| 版本 | GPU Device Utilization 中位/均值 | 进程 CPU 均值 | RSS 中位 |
| --- | --- | --- | --- |
| 基线 | 25.0% / 24.9% | 11.2–11.4% | 171.9 MB |
| 仅 P0（应用层） | 25.0% / 25.3% | 11.9% | 170.7 MB |
| P0 + P1 | 19.0% / 18.8% | 13.5% | 171.0 MB |

结论：GPU 收益来自 P1（约 -24%）；P0 不改变 GPU（出帧数不变，省的是唤醒），符合预期。CPU 侧 P1 有约 +1.6pp 的成本（多一次 present pass 与整场景 instance 编码），见已知问题。`ioreg` 的 Device Utilization 是整机 GPU（含 WindowServer 与其他后台负载）；无 App 的底噪轮因其他进程的 GPU 突发不可靠，因此未做底噪扣除，只保证三轮环境与 loadavg 同量级（2.2–2.9）。P0-only 的另一轮在构建刚结束、loadavg 3.2 时采到 GPU 32.8%，重采后与基线一致，属于噪声样本，不引用。

降级开关（无需重新编译）：`GPUI_EXPERIMENTAL_PARTIAL_RENDER=0` 关闭局部重绘（Metal 后端退回直绘全量路径），`GPUI_EXPERIMENTAL_PRESENT_SKIP=0` 关闭未变化帧跳过。

## 3. 绘制层：为什么没有改

对稳态展开的歌词页做插桩计数（13 行可见、2× 缩放）：410 个 glyph、22 个 layout/layer 批次，paint 约 11.5–14.1 µs/帧（60 FPS 下约 0.7–0.9 ms/秒），面板缓存命中时 prepaint 约 0.5 µs。glyph 数量已接近必要绘制；`scale == 1` 免逐 glyph 变换在 GPUI 里是 no-op（`paint_glyph` 本就走单位矩阵的 `paint_glyph_with_transformation`）；合并 layer/fragment 的收益低于 5% 且有绘制顺序风险。因此本层不做改动，性能收益来自减少帧数与减少重绘面积。

## 已知问题与限制

- **局部重绘的 CPU 成本**：固定配置真机测量，P1 让进程 CPU 从 11.2–11.4% 升到 13.5%（约 +1.6pp），GPU 利用率从 25% 降到 19%。隔离实验（P0-only 版本）显示 P0 本身不增加 GPU、CPU 差异在噪声内，因此增加的成本来自 P1：每帧仍要编码全场景 instance 数据，并多一次呈现 pass（持久纹理 copy 到 drawable）。这是用 CPU 换 GPU 的取舍；若后续要继续优化，优先做 instance 编码的增量更新或按帧类型跳过呈现，而不是关闭局部重绘。
- **场景 diff 会少报（既有 bug，非本次引入）**：快照里的 `SceneDamage::between` 在既有 property test 中会漏报极少数像素（观测为 path 合成边缘 1 LSB 单通道差异，最小复现是一次 Underline 平移导致 path batch 分组变化）。Linux

  /WGPU 后端同样使用这份 diff。它不阻塞 macOS 局部重绘，但属于契约完整性问题，需要独立修复；需要完全规避时用上面的 `GPUI_EXPERIMENTAL_PARTIAL_RENDER=0`。
- path batch 仍每帧付整屏中间纹理 clear + MSAA resolve（Apple GPU 的 MSAA 存储是 memoryless，无法 `Load`），当前只省了光栅化与合成。
- partial 帧的 present copy pass 有约 0.048 ms 的固定 GPU 成本，是脏区很小时的收益地板。
- 本机只有 Command Line Tools（无 `xcrun metal`），只验证了 `runtime_shaders`（运行时编译 shader）路径；Lyrune 构建使用的正是该路径，预编译 metallib 路径未验证。
- 真实窗口路径只做了离屏等价验证与真机进程测量，没有逐帧截图对比；本机没有 GUI 自动化。

## 验证方法

```bash
# 应用测试（138 passed / 3 ignored；运行前不要留 Lyrune 实例，单实例测试会与运行中的 app 冲突）
cargo test --locked --package lyrune

# fork 的像素等价测试（在 GPUI fork 工作区）
cargo test -p gpui-pre-apple --lib --features "runtime_shaders test-support" -- damage_tests::

# fork 的局部重绘 bench（需要 release）
cargo test --release -p gpui-pre-apple --lib --features "runtime_shaders test-support" -- damage_bench --ignored --nocapture --test-threads=1

# 真机进程测量（CPU/RSS/线程；--gpu 追加 ioreg GPU 利用率；无 sudo）
scripts/measure-macos-perf.sh --app target/release/lyrune --label candidate --duration 30 --playback --sample --gpu
```

真实播放场景需要人工操作：启动 app → 扫码登录 → 播放同一首歌 → 展开全屏歌词页 → 保持窗口前台（macOS 会停止被遮挡窗口的渲染）→ 再开始采样。两轮对比时固定同一首歌、同一窗口大小与同一帧率配置。

## 升级 GPUI 依赖

macOS 局部重绘在 GPUI fork 里，升级依赖时必须：

1. 在 fork 的对应快照分支上 cherry-pick 该 commit，或直接把 `[patch.crates-io]` 指向包含改动的新 rev；
2. 重跑 `damage_tests::` 与 `damage_bench`；
3. 真机复测 GPU 利用率与 CPU，确认没有回退；
4. 同步更新依赖仓库的 `LYRUNE-GPUI.md`。
