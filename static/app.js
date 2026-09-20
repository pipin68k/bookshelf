(() => {
  "use strict";

  const FORMAT_LABEL = { printed: "本", ebook: "電" };
  const UNTITLED = "(タイトル未設定)";

  const NDC1_LABELS = {
    "0": "総記", "1": "哲学", "2": "歴史", "3": "社会科学", "4": "自然科学",
    "5": "技術・工学", "6": "産業", "7": "芸術・美術", "8": "言語", "9": "文学",
  };

  const NDC2_LABELS = {
    "00": "総記", "01": "図書館・図書館学", "02": "図書・書誌学", "03": "百科事典", "04": "一般論文集・講演集",
    "05": "逐次刊行物", "06": "団体", "07": "ジャーナリズム・新聞", "08": "叢書・全集・選集", "09": "貴重書・郷土資料",
    "10": "哲学", "11": "哲学各論", "12": "東洋思想", "13": "西洋哲学", "14": "心理学",
    "15": "倫理学・道徳", "16": "宗教", "17": "神道", "18": "仏教", "19": "キリスト教・ユダヤ教",
    "20": "歴史", "21": "日本史", "22": "アジア史・東洋史", "23": "ヨーロッパ史・西洋史", "24": "アフリカ史",
    "25": "北アメリカ史", "26": "南アメリカ史", "27": "オセアニア史・両極地方史", "28": "伝記", "29": "地理・地誌・紀行",
    "30": "社会科学", "31": "政治", "32": "法律", "33": "経済", "34": "財政",
    "35": "統計", "36": "社会", "37": "教育", "38": "風俗習慣・民俗学", "39": "国防・軍事",
    "40": "自然科学", "41": "数学", "42": "物理学", "43": "化学", "44": "天文学・宇宙科学",
    "45": "地球科学・地学", "46": "生物科学・一般生物学", "47": "植物学", "48": "動物学", "49": "医学・薬学",
    "50": "技術・工学", "51": "建設工学・土木工学", "52": "建築学", "53": "機械工学", "54": "電気工学・電子工学",
    "55": "海洋工学・船舶工学", "56": "金属工学・鉱山工学", "57": "化学工業", "58": "製造工業", "59": "家政学・生活科学",
    "60": "産業", "61": "農業", "62": "園芸", "63": "蚕糸業", "64": "畜産業・獣医学",
    "65": "林業", "66": "水産業", "67": "商業", "68": "運輸・交通", "69": "通信事業",
    "70": "芸術・美術", "71": "彫刻", "72": "絵画", "73": "版画", "74": "写真・印刷",
    "75": "工芸", "76": "音楽・舞踊", "77": "演劇・映画", "78": "スポーツ・体育", "79": "諸芸・娯楽",
    "80": "言語", "81": "日本語", "82": "中国語", "83": "英語", "84": "ドイツ語",
    "85": "フランス語", "86": "スペイン語", "87": "イタリア語", "88": "ロシア語", "89": "その他の諸言語",
    "90": "文学", "91": "日本文学", "92": "中国文学・東洋文学", "93": "英米文学", "94": "ドイツ文学",
    "95": "フランス文学", "96": "スペイン文学", "97": "イタリア文学", "98": "ロシア文学", "99": "その他の諸文学",
  };

  // --- catalog construction (ported from the app's former Go backend) ---

  function padVolume(vol) {
    if (!vol) return "";
    let digits = 0;
    while (digits < vol.length && vol[digits] >= "0" && vol[digits] <= "9") digits++;
    if (digits === 0) return "~" + vol;
    const numPart = vol.slice(0, digits).padStart(10, "0");
    return numPart + vol.slice(digits);
  }

  function toView(book) {
    let title = book.title || "";
    if (title === "" || title === "(無題)") {
      title = book.isbn13 || UNTITLED;
    }
    const subtitle = book.series || book.label || "";
    const ndc = book.ndc || "";
    const view = {
      id: book.id,
      isbn13: book.isbn13 || "",
      title,
      subtitle,
      author: book.author || "",
      publisher: book.publisher || "",
      pubyear: book.pubyear || "",
      ndc,
      ndc1: ndc ? ndc.slice(0, 1) : "",
      ndc2: ndc.length >= 2 ? ndc.slice(0, 2) : "",
      format: book.format,
      seriesKey: book.series || title,
      sortVol: padVolume(book.vol || ""),
    };
    return view;
  }

  function compareViews(a, b) {
    if ((a.ndc === "") !== (b.ndc === "")) return a.ndc === "" ? 1 : -1;
    if (a.ndc !== b.ndc) return a.ndc < b.ndc ? -1 : 1;
    if (a.seriesKey !== b.seriesKey) return a.seriesKey < b.seriesKey ? -1 : 1;
    if (a.sortVol !== b.sortVol) return a.sortVol < b.sortVol ? -1 : 1;
    if (a.title !== b.title) return a.title < b.title ? -1 : 1;
    return 0;
  }

  function buildNDCTree(views) {
    const firstCount = {};
    const secondCount = {};
    let unclassified = 0;

    for (const v of views) {
      if (v.ndc1 === "") {
        unclassified++;
        continue;
      }
      firstCount[v.ndc1] = (firstCount[v.ndc1] || 0) + 1;
      secondCount[v.ndc1] = secondCount[v.ndc1] || {};
      secondCount[v.ndc1][v.ndc2] = (secondCount[v.ndc1][v.ndc2] || 0) + 1;
    }

    const tree = [];
    for (let d = 0; d <= 9; d++) {
      const key = String(d);
      const count = firstCount[key];
      if (!count) continue;
      const children = Object.entries(secondCount[key] || {})
        .map(([code, c]) => ({ code, label: NDC2_LABELS[code] || "", count: c }))
        .sort((a, b) => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0));
      tree.push({ code: key, label: NDC1_LABELS[key] || "", count, children });
    }
    return { tree, unclassified };
  }

  function buildCatalog(rawBooks) {
    const books = rawBooks.map(toView).sort(compareViews);
    const { tree, unclassified } = buildNDCTree(books);
    return { books, ndcTree: tree, unclassified, total: books.length };
  }

  // --- config application ---

  function applyConfig(cfg) {
    document.documentElement.style.setProperty("--base-font-size", cfg.baseFontSize || "16px");
    const breakpoint = cfg.menuHiddenBreakpoint || 768;
    const styleEl = document.createElement("style");
    styleEl.textContent = `@media (max-width: ${breakpoint}px) { #sidebar { display: none; } }`;
    document.head.appendChild(styleEl);
  }

  // --- rendering ---

  const menuEl = document.getElementById("ndc-menu");
  const searchEl = document.getElementById("search");
  const countEl = document.getElementById("count");
  const rowsEl = document.getElementById("book-rows");
  const formatRadios = document.querySelectorAll('input[name="format"]');

  let catalog = null;
  let enableCalilLink = true;

  // selection: {level: "all"} | {level: "ndc1", code} | {level: "ndc2", code} | {level: "unclassified"}
  let selection = { level: "all" };
  let expanded = null; // ndc1 code currently expanded in the menu

  function buildMenu() {
    menuEl.innerHTML = "";

    const allLi = menuItem("すべて", catalog.total, selection.level === "all", () => {
      selection = { level: "all" };
      expanded = null;
      render();
    });
    allLi.classList.add("menu-all");
    menuEl.appendChild(allLi);

    for (const node of catalog.ndcTree) {
      const li = menuItem(`${node.code} ${node.label}`, node.count,
        selection.level === "ndc1" && selection.code === node.code, () => {
          selection = { level: "ndc1", code: node.code };
          expanded = expanded === node.code ? null : node.code;
          render();
        });
      menuEl.appendChild(li);

      if (expanded === node.code && node.children) {
        const sub = document.createElement("ul");
        sub.className = "submenu";
        for (const child of node.children) {
          const label = child.label ? `${child.code} ${child.label}` : child.code;
          const subLi = menuItem(label, child.count,
            selection.level === "ndc2" && selection.code === child.code, () => {
              selection = { level: "ndc2", code: child.code };
              render();
            });
          sub.appendChild(subLi);
        }
        menuEl.appendChild(sub);
      }
    }

    if (catalog.unclassified > 0) {
      const li = menuItem("NDC未設定", catalog.unclassified,
        selection.level === "unclassified", () => {
          selection = { level: "unclassified" };
          expanded = null;
          render();
        });
      li.classList.add("menu-unclassified");
      menuEl.appendChild(li);
    }
  }

  function menuItem(label, count, active, onClick) {
    const li = document.createElement("li");
    li.className = "menu-item" + (active ? " active" : "");
    const labelSpan = document.createElement("span");
    labelSpan.className = "menu-label";
    labelSpan.textContent = label;
    const countSpan = document.createElement("span");
    countSpan.className = "menu-count";
    countSpan.textContent = count;
    li.appendChild(labelSpan);
    li.appendChild(countSpan);
    li.addEventListener("click", onClick);
    return li;
  }

  function matchesSelection(book) {
    switch (selection.level) {
      case "ndc1":
        return book.ndc1 === selection.code;
      case "ndc2":
        return book.ndc2 === selection.code;
      case "unclassified":
        return book.ndc === "";
      default:
        return true;
    }
  }

  function currentFormat() {
    for (const r of formatRadios) if (r.checked) return r.value;
    return "all";
  }

  function matchesFormat(book, format) {
    if (format === "all") return true;
    return book.format === format;
  }

  function matchesQuery(book, query) {
    if (!query) return true;
    return book.title.toLowerCase().includes(query) || book.author.toLowerCase().includes(query);
  }

  function render() {
    buildMenu();

    const query = searchEl.value.trim().toLowerCase();
    const format = currentFormat();
    const filtered = catalog.books.filter(
      (b) => matchesSelection(b) && matchesFormat(b, format) && matchesQuery(b, query)
    );

    countEl.textContent = `${filtered.length} / ${catalog.total} 冊`;

    rowsEl.innerHTML = "";
    const frag = document.createDocumentFragment();
    for (const book of filtered) {
      frag.appendChild(renderRow(book));
    }
    rowsEl.appendChild(frag);
  }

  function renderRow(book) {
    const tr = document.createElement("tr");

    const ndcTd = document.createElement("td");
    ndcTd.className = "col-ndc";
    ndcTd.textContent = book.ndc || "―";
    tr.appendChild(ndcTd);

    const titleTd = document.createElement("td");
    titleTd.className = "col-title";
    if (enableCalilLink && book.isbn13) {
      const a = document.createElement("a");
      a.href = `https://calil.jp/book/${book.isbn13}`;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = book.title;
      titleTd.appendChild(a);
    } else {
      titleTd.textContent = book.title;
    }
    if (book.subtitle) {
      const sub = document.createElement("div");
      sub.className = "subtitle";
      sub.textContent = book.subtitle;
      titleTd.appendChild(sub);
    }
    tr.appendChild(titleTd);

    tr.appendChild(textCell(book.author, "col-author"));
    tr.appendChild(textCell(book.publisher, "col-publisher"));
    tr.appendChild(textCell(book.pubyear, "col-year"));
    tr.appendChild(textCell(FORMAT_LABEL[book.format] || book.format, "col-format"));

    return tr;
  }

  function textCell(text, className) {
    const td = document.createElement("td");
    td.className = className;
    td.textContent = text || "";
    return td;
  }

  let searchTimer = null;
  searchEl.addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(render, 120);
  });
  for (const r of formatRadios) r.addEventListener("change", render);

  // --- boot ---

  async function main() {
    const [cfg, rawBooks] = await Promise.all([
      fetch("config.json").then((r) => r.json()),
      fetch("data/books.json").then((r) => r.json()),
    ]);
    applyConfig(cfg);
    enableCalilLink = cfg.enableCalilLink !== false;
    catalog = buildCatalog(rawBooks);
    render();
  }

  main().catch((err) => {
    console.error(err);
    document.getElementById("count").textContent = "読み込みに失敗しました: " + err.message;
  });
})();
