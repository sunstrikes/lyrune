use std::time::{Duration, Instant};

use crate::settings::FrameRate;

pub(super) fn frame_is_due(
    now: Instant,
    frame_rate: FrameRate,
    next_frame: &mut Option<Instant>,
) -> bool {
    let Some(interval) = frame_rate.frame_interval() else {
        *next_frame = None;
        return true;
    };
    let Some(deadline) = *next_frame else {
        *next_frame = Some(now + interval);
        return false;
    };
    if now < deadline {
        return false;
    }

    // 正常帧沿用原来的截止时间，避免每次从 now 计时导致累计漂移；落后整帧才重置。
    let delay = now.saturating_duration_since(deadline);
    *next_frame = Some(if delay < interval {
        deadline + interval
    } else {
        now + interval
    });
    true
}

/// 距限帧截止点还需等待的时长；`None` 表示当前帧就该绘制（不限帧或已到期），
/// 调用方不应再为这一帧等待定时器。
pub(super) fn frame_wake_delay(now: Instant, next_frame: Option<Instant>) -> Option<Duration> {
    next_frame
        .map(|deadline| deadline.saturating_duration_since(now))
        .filter(|delay| !delay.is_zero())
}
