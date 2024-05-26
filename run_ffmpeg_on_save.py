#!/usr/bin/env python3

import json
import sys
import argparse
import subprocess

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--save-file-path", required=True)
    parser.add_argument("--video-path", required=True)

    return parser.parse_args()


class FfmpegFilterGenerator:
    def __init__(self, input):
        self.segment_idx = 0
        self.output = ["ffmpeg", "-i", input, "-filter_complex", ""]

    def add_segment(self, start, end):
        self.output[len(self.output) - 1] += f"[0:v]trim=start={start}:end={end},setpts=PTS-STARTPTS[{self.segment_idx}v];"
        self.output[len(self.output) - 1] += f"[0:a]atrim=start={start}:end={end},asetpts=PTS-STARTPTS[{self.segment_idx}a];"
        self.segment_idx += 1

    def finish(self, output_file):
        for i in range(0,self.segment_idx):
            self.output[len(self.output) - 1] += f"[{i}v][{i}a]"
        self.output[len(self.output) - 1] += f"concat=n={self.segment_idx}:v=1:a=1[outv][outa]"
        self.output += ["-map", "[outv]", "-map", "[outa]", output_file]

def main(video_path, save_file_path):
    with open(save_file_path) as f:
        save_file = json.load(f)


    generator = FfmpegFilterGenerator(video_path)
    for segment in save_file["clips"]:
        generator.add_segment(segment["start"], segment["end"])
    generator.finish("out.mkv")

    subprocess.run(generator.output, check=True)

if __name__ == '__main__':
    main(**vars(parse_args()))
