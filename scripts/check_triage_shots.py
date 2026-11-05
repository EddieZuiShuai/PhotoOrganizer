#!/usr/bin/env python3
"""检查「逐张过」滑过之后，卡片里的图片真的换了。

计数器从 1/12 变成 2/12 并不能证明图片换了 —— 之前的 bug 就是
数字在动、图片停在上一张。这里直接比较两次截图里卡片区域的颜色分布。
"""

import sys
from PIL import Image, ImageChops, ImageStat

# 卡片大致占屏幕中间这一块，避开状态栏、进度条和底部按钮
CROP = (0.10, 0.20, 0.90, 0.72)
DIFF_MIN = 6.0     # 平均通道差（0-255）
STD_MIN = 3.0      # 整块不能是纯色/空白


def load(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    box = (int(w * CROP[0]), int(h * CROP[1]), int(w * CROP[2]), int(h * CROP[3]))
    return im.crop(box).resize((48, 48))


def stats(im):
    s = ImageStat.Stat(im)
    std = sum(s.stddev) / 3.0
    mean = tuple(round(v, 1) for v in s.mean)
    return std, mean


def main():
    if len(sys.argv) != 3:
        print("用法: check_triage_shots.py before.png after.png")
        return 2

    a, b = load(sys.argv[1]), load(sys.argv[2])
    std_a, mean_a = stats(a)
    std_b, mean_b = stats(b)

    diff = ImageChops.difference(a, b)
    avg = sum(ImageStat.Stat(diff).mean) / 3.0

    print("第一张：均值 RGB=%s 标准差=%.2f" % (mean_a, std_a))
    print("第二张：均值 RGB=%s 标准差=%.2f" % (mean_b, std_b))
    print("两张卡片区域的平均差异：%.2f / 255" % avg)

    if std_a < STD_MIN or std_b < STD_MIN:
        print("失败：卡片区域几乎是纯色，可能根本没加载出图片（空白页）")
        return 1
    if avg < DIFF_MIN:
        print("失败：滑过之后画面几乎没变（差 %.2f < %.2f）—— 图片很可能没跟着换" % (avg, DIFF_MIN))
        return 1

    print("通过：滑过之后卡片画面明显变化")
    return 0


if __name__ == "__main__":
    sys.exit(main())
