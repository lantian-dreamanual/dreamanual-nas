#!/usr/bin/env node
// 生成「区县 → 地级市 / 省」对照表（app 内置资源）。
//
// 为什么需要：群晖照片的地点条目只有 `first_level`（龙游县 / 浦东新区 /
// 兰溪市 —— 区、县、县级市、地级市混在一层）+ `second_level`（乡镇街道），
// **没有市与省**，也没有任何 additional 能取到（photosprobe64 实测全 120）。
// 于是「搜衢州命中龙游」只能客户端补一张区划表。
//
// 数据源：npm 包 `china-division`（民政部区划代码，省/市/区县三级）。
// 它只在生成时用，不入库；产物 `DreamanualNAS/Resources/ChinaDivisions.json`
// 入库（约 100 KB），构建不依赖网络与 npm。
//
// 用法：node scripts/gen-divisions.mjs
//   包不在默认位置时给路径：node scripts/gen-divisions.mjs /path/to/pca-code.json

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "..");
const DEFAULT_SRC =
  "/Users/lantian/.workbuddy/binaries/node/workspace/node_modules/china-division/dist/pca-code.json";
const SRC = process.argv[2] || DEFAULT_SRC;
const OUT = path.join(ROOT, "DreamanualNAS/Resources/ChinaDivisions.json");

// 省级直辖的县级单位（city 层写「省直辖县级行政区划」）：归到省，不编一个市。
// 直辖市（city 层写「市辖区」）：市 = 省名。
const MUNICIPALITIES = new Set(["北京市", "上海市", "天津市", "重庆市"]);

// 群晖的 first_level 里会出现**乡镇级**名字（实测 99 个一级区划里有 12 个是
// 街道 / 镇 / 社区）。它们不在区县表里，这里手工补：乡镇 → [所属县级市/区, 地级市, 省]。
// 只补实际出现过的（2026-10-21 按 NAS 上 291 个地点实测补齐，合计 75 张照片）；
// 缺了新照片时 gen 会把未命中的列出来，再补。
const MANUAL = {
  武夷街道: ["武夷山市", "南平市", "福建省"],
  杏林街道: ["集美区", "厦门市", "福建省"],
  鹭江街道: ["思明区", "厦门市", "福建省"],
  祥符街道: ["拱墅区", "杭州市", "浙江省"],
  开元街道: ["思明区", "厦门市", "福建省"],
  兴田镇: ["武夷山市", "南平市", "福建省"],
  江湾镇: ["婺源县", "上饶市", "江西省"],
  裕南街街道: ["天心区", "长沙市", "湖南省"],
  仙林街道: ["栖霞区", "南京市", "江苏省"],
  蜀麓社区: ["蜀山区", "合肥市", "安徽省"],
  城厢镇: ["太仓市", "苏州市", "江苏省"],
  转塘街道: ["西湖区", "杭州市", "浙江省"],
  乌兰木伦镇: ["伊金霍洛旗", "鄂尔多斯市", "内蒙古自治区"],
  秋口镇: ["婺源县", "上饶市", "江西省"],
  紫阳镇: ["婺源县", "上饶市", "江西省"],
};

function main() {
  const data = JSON.parse(fs.readFileSync(SRC, "utf8"));
  /** @type {Record<string, [string, string]>} */
  const table = {};
  let counties = 0;

  for (const prov of data) {
    const province = prov.name;
    for (const city of prov.children || []) {
      let cityName = city.name;
      if (MUNICIPALITIES.has(province)) cityName = province;
      if (cityName.includes("省直辖") || cityName === "市辖区" || cityName === "县") {
        cityName = province;
      }
      for (const area of city.children || []) {
        // 后出现的覆盖先出现的：同名区县跨市重名时，后写入的不一定更对，
        // 但重名的都是「市辖区」这类（如「城区」），错误代价只是归错组。
        table[area.name] = [cityName, province];
        counties += 1;
      }
    }
  }

  // 县级市也会作为 first_level 出现（兰溪市 / 江山市），pca 表里它们就在「区县」层，已覆盖。
  // 地级市本身作为 first_level（沈阳市 / 厦门市）也要能查到：市名 → [自己, 省]。
  for (const prov of data) {
    for (const city of prov.children || []) {
      if (!table[city.name]) table[city.name] = [city.name, prov.name];
    }
  }

  for (const [name, triple] of Object.entries(MANUAL)) {
    table[name] = [triple[1], triple[2]];
  }

  const sorted = {};
  for (const key of Object.keys(table).sort((a, b) => a.localeCompare(b, "zh"))) {
    sorted[key] = table[key];
  }

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  const text = JSON.stringify(sorted);
  fs.writeFileSync(OUT, text + "\n");
  console.log(`写出 ${path.relative(ROOT, OUT)}：${Object.keys(sorted).length} 条（区县 ${counties}）`
              + `，${(Buffer.byteLength(text) / 1024).toFixed(1)} KB`);

  // 抽查几条用户实际遇到的
  for (const probe of ["龙游县", "浦东新区", "黄浦区", "兰溪市", "武夷街道", "沈阳市", "达拉特旗"]) {
    console.log(`  ${probe} → ${JSON.stringify(sorted[probe] || null)}`);
  }
}

main();
