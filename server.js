// ============================================================
//  聊天工坊 - 双人聊天 & 小游戏服务器（Node.js 版，零依赖）
//  本地运行： node server.js
//  云端运行： 平台自动注入 PORT，直接 npm start
// ============================================================
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 8765;
const RECHARGE_PWD = process.env.RECHARGE_PWD || '123321';
const DATA_FILE = process.env.DATA_FILE || path.join(__dirname, 'data.json');
const HTML_FILE = path.join(__dirname, 'index.html');

// ---------- 全局状态（Node 单线程，无需加锁） ----------
const state = { seq: 1, users: {}, convs: {}, games: {}, tokens: {} };

const now = () => Date.now();
const hashPwd = (pwd) => crypto.createHash('sha256').update(pwd + '_chat_salt_2026', 'utf8').digest('hex');
const newToken = () => crypto.randomBytes(24).toString('hex');
const convKey = (a, b) => [a, b].sort().join('__');
const nickOf = (name) => (state.users[name] ? state.users[name].nick : name);

function addMsg(sender, receiver, type, content, gameId) {
  const key = convKey(sender, receiver);
  if (!state.convs[key]) state.convs[key] = [];
  const msg = {
    id: 'm' + state.seq + '_' + Math.floor(Math.random() * 999999),
    sender, receiver, type, content,
    gameId: gameId || '',
    ts: now(), recalled: false
  };
  state.convs[key].push(msg);
  state.seq++;
  return msg;
}

function saveState() {
  try {
    const convs = {};
    for (const k of Object.keys(state.convs)) convs[k] = state.convs[k];
    const obj = { seq: state.seq, users: state.users, convs };
    fs.writeFileSync(DATA_FILE, JSON.stringify(obj), 'utf8');
  } catch (e) { console.error('保存失败:', e.message); }
}

function loadState() {
  if (!fs.existsSync(DATA_FILE)) return;
  try {
    const data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
    if (data.seq) state.seq = parseInt(data.seq, 10) || 1;
    if (data.users) {
      for (const [name, u] of Object.entries(data.users)) {
        state.users[name] = { pwd: u.pwd, nick: u.nick, chips: parseInt(u.chips, 10) || 0, lastSeen: 0 };
      }
    }
    if (data.convs) {
      for (const [k, list] of Object.entries(data.convs)) state.convs[k] = list;
    }
    console.log('已加载历史数据（用户 ' + Object.keys(state.users).length + ' 个）');
  } catch (e) { console.error('数据加载失败:', e.message); }
}

function getMe(token) {
  if (!token) return null;
  const name = state.tokens[token];
  if (name && state.users[name]) return name;
  return null;
}

// ---------- 扑克牌 ----------
function newDeck() {
  const suits = ['♠', '♥', '♦', '♣'];
  const ranks = ['A','2','3','4','5','6','7','8','9','10','J','Q','K'];
  const deck = [];
  for (let si = 0; si < 4; si++) {
    for (let i = 0; i < 13; i++) {
      deck.push({ s: suits[si], r: ranks[i], v: i + 1, nv: i >= 10 ? 10 : i + 1 });
    }
  }
  for (let i = deck.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    const t = deck[i]; deck[i] = deck[j]; deck[j] = t;
  }
  return deck;
}

// ---------- 牛牛 ----------
function checkSpecial(cards) {
  const vals = cards.map(c => parseInt(c.nv, 10));
  const bigCount = cards.filter(c => parseInt(c.v, 10) > 5).length;
  const allSmall = bigCount === 0 && vals.reduce((a, b) => a + b, 0) <= 10;
  if (allSmall) return { name: '五小牛', score: 1000 };
  if (cards.filter(c => parseInt(c.v, 10) < 11).length === 0) return { name: '五花牛', score: 900 };
  for (let i = 1; i <= 13; i++) {
    if (cards.filter(c => parseInt(c.v, 10) === i).length >= 4) return { name: '炸弹', score: 800 };
  }
  return null;
}

function evalManualNiu(cards, selIdx) {
  const vals = cards.map(c => parseInt(c.nv, 10));
  const sum3 = selIdx.reduce((a, i) => a + vals[i], 0);
  if (sum3 % 10 !== 0) return null;
  const rest = [0,1,2,3,4].filter(i => selIdx.indexOf(i) < 0);
  const niu = (vals[rest[0]] + vals[rest[1]]) % 10;
  if (niu === 0) return { name: '牛牛', score: 700, selIdx };
  return { name: '牛' + niu, score: 100 + niu * 10, selIdx };
}

function evalNiuNiu(cards) {
  const sp = checkSpecial(cards);
  if (sp) return sp;
  const vals = cards.map(c => parseInt(c.nv, 10));
  let best = -1;
  for (let a = 0; a < 5; a++)
    for (let b = a + 1; b < 5; b++)
      for (let c = b + 1; c < 5; c++) {
        if ((vals[a] + vals[b] + vals[c]) % 10 === 0) {
          const rest = [0,1,2,3,4].filter(i => i !== a && i !== b && i !== c);
          const niu = (vals[rest[0]] + vals[rest[1]]) % 10;
          if (niu > best) best = niu;
        }
      }
  if (best >= 0) {
    if (best === 0) return { name: '牛牛', score: 700 };
    return { name: '牛' + best, score: 100 + best * 10 };
  }
  return { name: '没牛', score: 0 };
}

function endNiuNiu(g) {
  const h = g.hostResult || evalNiuNiu(g.hostCards);
  const gu = g.guestResult || evalNiuNiu(g.guestCards);
  g.status = 'ended';
  const hn = nickOf(g.host), gn = nickOf(g.guest);
  if (h.score === gu.score) { awardPot(g, null); g.result = '平局：双方都是 ' + h.name + '，奖池平分'; }
  else if (h.score > gu.score) { awardPot(g, g.host); g.result = hn + ' 的【' + h.name + '】战胜 ' + gn + ' 的【' + gu.name + '】'; }
  else { awardPot(g, g.guest); g.result = gn + ' 的【' + gu.name + '】战胜 ' + hn + ' 的【' + h.name + '】'; }
  g.lastAction = g.result;
  addMsg(g.host, g.guest, 'system', '🐂 牛牛结束：' + g.result + '，奖池 ' + g.pot + ' 筹码', g.id);
}

// ---------- 炸金花 ----------
function evalZjh(cards) {
  const sorted = cards.slice().sort((a, b) => parseInt(b.v, 10) - parseInt(a.v, 10));
  const vals = sorted.map(c => parseInt(c.v, 10));
  const suits = sorted.map(c => c.s);
  const isFlush = suits[0] === suits[1] && suits[1] === suits[2];
  const isTriple = vals[0] === vals[1] && vals[1] === vals[2];
  const isPair = vals[0] === vals[1] || vals[1] === vals[2];
  const isStraight = (vals[0] - vals[1] === 1 && vals[1] - vals[2] === 1) ||
                     (vals[0] === 13 && vals[1] === 12 && vals[2] === 1);
  if (isTriple) return { name: '豹子', score: 600 + vals[0] * 10 };
  if (isFlush && isStraight) {
    const high = (vals[0] === 13 && vals[2] === 1) ? 14 : vals[0];
    return { name: '顺金', score: 500 + high * 10 };
  }
  if (isFlush) return { name: '金花', score: 400 + vals[0] * 100 + vals[1] * 10 + vals[2] };
  if (isStraight) {
    const high = (vals[0] === 13 && vals[2] === 1) ? 14 : vals[0];
    return { name: '顺子', score: 300 + high * 10 };
  }
  if (isPair) {
    const pairVal = (vals[0] === vals[1]) ? vals[0] : vals[1];
    const singleVal = (vals[0] === vals[1]) ? vals[2] : vals[0];
    return { name: '对子', score: 200 + pairVal * 10 + singleVal };
  }
  return { name: '单张', score: 100 + vals[0] * 10 + vals[1] + vals[2] * 0.1 };
}

function endZjh(g, reason) {
  const h = evalZjh(g.hostCards);
  const gu = evalZjh(g.guestCards);
  g.status = 'ended';
  const hn = nickOf(g.host), gn = nickOf(g.guest);
  if (reason !== 'fold') {
    if (h.score === gu.score) { awardPot(g, null); g.result = '平局：双方都是 ' + h.name + '，奖池平分'; }
    else if (h.score > gu.score) { awardPot(g, g.host); g.result = hn + ' 的【' + h.name + '】战胜 ' + gn + ' 的【' + gu.name + '】'; }
    else { awardPot(g, g.guest); g.result = gn + ' 的【' + gu.name + '】战胜 ' + hn + ' 的【' + h.name + '】'; }
  }
  g.lastAction = g.result;
  addMsg(g.host, g.guest, 'system', '🎮 炸金花结束：' + g.result + '，奖池 ' + g.pot + ' 筹码', g.id);
}

// ---------- 港式五张（梭哈） ----------
const SUIT_RANK = { '♠': 4, '♥': 3, '♣': 2, '♦': 1 };
function evalShowhand(cards) {
  const vals = cards.map(c => { const vv = parseInt(c.v, 10); return vv === 1 ? 14 : vv; });
  const suits = cards.map(c => c.s);
  const desc = vals.slice().sort((a, b) => b - a);
  const cnt = {};
  for (const v of vals) cnt[v] = (cnt[v] || 0) + 1;
  const fours = Object.keys(cnt).filter(k => cnt[k] === 4).map(Number);
  const trips = Object.keys(cnt).filter(k => cnt[k] === 3).map(Number);
  const pairs = Object.keys(cnt).filter(k => cnt[k] === 2).map(Number).sort((a, b) => b - a);
  const uniq = vals.slice().sort((a, b) => a - b);
  const isFlush = suits.filter((s, i) => i === 0 || s === suits[0]).length === 5;
  let isStraight = false, straightHigh = 0;
  if (uniq.length === 5) {
    if (desc[0] - desc[4] === 4) { isStraight = true; straightHigh = desc[0]; }
    if (uniq.join(',') === '2,3,4,5,14') { isStraight = true; straightHigh = 5; }
  }
  const encodeSig = (ranks) => ranks.reduce((code, r) => code * 15 + parseInt(r, 10), 0);
  let cat = 0, name = '散牌', sig = desc;
  if (isStraight && isFlush) { cat = 8; name = '同花顺'; sig = [straightHigh]; }
  else if (fours.length === 1) { cat = 7; name = '四条'; sig = [fours[0]].concat(vals.filter(v => v !== fours[0])); }
  else if (trips.length === 1 && pairs.length === 1) { cat = 6; name = '葫芦'; sig = [trips[0], pairs[0]]; }
  else if (isFlush) { cat = 5; name = '同花'; sig = desc; }
  else if (isStraight) { cat = 4; name = '顺子'; sig = [straightHigh]; }
  else if (trips.length === 1) {
    cat = 3; name = '三条';
    sig = [trips[0]].concat(vals.filter(v => v !== trips[0]).sort((a, b) => b - a));
  }
  else if (pairs.length === 2) {
    cat = 2; name = '两对';
    sig = [pairs[0], pairs[1]].concat(vals.filter(v => v !== pairs[0] && v !== pairs[1]));
  }
  else if (pairs.length === 1) {
    cat = 1; name = '对子';
    sig = [pairs[0]].concat(vals.filter(v => v !== pairs[0]).sort((a, b) => b - a));
  }
  const score = cat * 1000000 + encodeSig(sig);
  const maxV = desc[0];
  let suitTop = 0;
  for (let i = 0; i < 5; i++) if (vals[i] === maxV && SUIT_RANK[suits[i]] > suitTop) suitTop = SUIT_RANK[suits[i]];
  return { name, score, suitTop };
}

function awardPot(g, winnerName) {
  if (winnerName) {
    state.users[winnerName].chips = parseInt(state.users[winnerName].chips, 10) + parseInt(g.pot, 10);
    g.winner = winnerName;
  } else {
    const half = Math.floor(parseInt(g.pot, 10) / 2);
    state.users[g.host].chips = parseInt(state.users[g.host].chips, 10) + half;
    state.users[g.guest].chips = parseInt(state.users[g.guest].chips, 10) + (parseInt(g.pot, 10) - half);
    g.winner = '';
  }
}

function endShowhand(g) {
  const h = evalShowhand([g.hostHole].concat(g.hostUp));
  const gu = evalShowhand([g.guestHole].concat(g.guestUp));
  g.status = 'ended';
  const hn = nickOf(g.host), gn = nickOf(g.guest);
  if (h.score === gu.score) {
    if (h.suitTop === gu.suitTop) { awardPot(g, null); g.result = '平局：双方都是 ' + h.name + '，奖池平分'; }
    else if (h.suitTop > gu.suitTop) { awardPot(g, g.host); g.result = hn + ' 的【' + h.name + '】以花色胜出 ' + gn + ' 的【' + gu.name + '】'; }
    else { awardPot(g, g.guest); g.result = gn + ' 的【' + gu.name + '】以花色胜出 ' + hn + ' 的【' + h.name + '】'; }
  } else if (h.score > gu.score) {
    awardPot(g, g.host); g.result = hn + ' 的【' + h.name + '】战胜 ' + gn + ' 的【' + gu.name + '】';
  } else {
    awardPot(g, g.guest); g.result = gn + ' 的【' + gu.name + '】战胜 ' + hn + ' 的【' + h.name + '】';
  }
  g.lastAction = g.result;
  addMsg(g.host, g.guest, 'system', '🎴 梭哈结束：' + g.result + '，奖池 ' + g.pot + ' 筹码', g.id);
}

function showhandFirst(g) {
  const hv = g.hostUp.map(c => { const vv = parseInt(c.v, 10); return vv === 1 ? 14 : vv; });
  const gv = g.guestUp.map(c => { const vv = parseInt(c.v, 10); return vv === 1 ? 14 : vv; });
  const hm = Math.max.apply(null, hv), gm = Math.max.apply(null, gv);
  return gm > hm ? g.guest : g.host;
}

function advanceShowhand(g) {
  g.hostStreet = 0; g.guestStreet = 0;
  g.hostActed = false; g.guestActed = false;
  g.currentBet = 0;
  if (g.hostUp.length >= 4) { endShowhand(g); return; }
  const n = g.hostUp.length;
  g.hostUp.push(g.deck[2 + 2 * n]);
  g.guestUp.push(g.deck[3 + 2 * n]);
  g.street++;
  g.turn = showhandFirst(g);
  g.lastAction = '第 ' + g.street + ' 张明牌发出，轮到 ' + nickOf(g.turn) + ' 说话';
}

// ---------- 游戏视图（向单个玩家隐藏对手底牌） ----------
function buildGameView(g, me) {
  const iAmHost = g.host === me;
  const myCards = iAmHost ? g.hostCards : g.guestCards;
  const oppName = iAmHost ? g.guest : g.host;
  let oppCards = null, oppSeen = false;
  if (g.status === 'ended') { oppCards = iAmHost ? g.guestCards : g.hostCards; oppSeen = true; }
  const myLooked = iAmHost ? g.hostLooked : g.guestLooked;
  const myFolded = iAmHost ? g.hostFolded : g.guestFolded;
  const myOpened = iAmHost ? g.hostOpened : g.guestOpened;
  const oppLooked = iAmHost ? g.guestLooked : g.hostLooked;
  const oppFolded = iAmHost ? g.guestFolded : g.hostFolded;
  const oppOpened = iAmHost ? g.guestOpened : g.hostOpened;
  let showMyCards = true;
  if (g.type === 'zhajinhua' && !myLooked && g.status !== 'ended') showMyCards = false;
  const mySelection = iAmHost ? g.hostSelection : g.guestSelection;
  const myResult = iAmHost ? g.hostResult : g.guestResult;
  const mySubmitted = !!(iAmHost ? g.hostSubmitted : g.guestSubmitted);
  const oppSubmitted = !!(iAmHost ? g.guestSubmitted : g.hostSubmitted);
  let oppSelection = null;
  if (g.status === 'ended' && g.type === 'niuniu') {
    oppSelection = iAmHost ? g.guestSelection : g.hostSelection;
  }
  let myHole = null, myUp = [], oppHole = null, oppUp = [];
  if (g.type === 'showhand') {
    if (iAmHost) {
      myHole = g.hostHole; myUp = g.hostUp.slice(); oppUp = g.guestUp.slice();
      if (g.status === 'ended') oppHole = g.guestHole;
    } else {
      myHole = g.guestHole; myUp = g.guestUp.slice(); oppUp = g.hostUp.slice();
      if (g.status === 'ended') oppHole = g.hostHole;
    }
  }
  return {
    id: g.id, type: g.type, status: g.status,
    host: g.host, guest: g.guest,
    hostNick: nickOf(g.host), guestNick: nickOf(g.guest),
    bet: g.bet, pot: g.pot, currentBet: g.currentBet, round: g.round,
    turn: g.turn, winner: g.winner, result: g.result, lastAction: g.lastAction,
    iAmHost, myName: me, oppName,
    myNick: nickOf(me), oppNick: nickOf(oppName),
    myCards: myCards || [], showMyCards,
    myLooked: !!myLooked, myFolded: !!myFolded, myOpened: !!myOpened,
    oppCards: oppCards || null, oppSeen,
    oppLooked: !!oppLooked, oppFolded: !!oppFolded, oppOpened: !!oppOpened,
    mySelection: mySelection || null,
    myResult: myResult || null, mySubmitted, oppSubmitted,
    oppSelection: oppSelection || null,
    myHole, myUp, oppHole, oppUp,
    street: g.street || 0,
    myStreetPaid: iAmHost ? (g.hostStreet || 0) : (g.guestStreet || 0),
    oppStreetPaid: iAmHost ? (g.guestStreet || 0) : (g.hostStreet || 0)
  };
}

// ---------- API 路由 ----------
function handleApi(pathname, query, req) {
  // 注册
  if (pathname === '/api/register' && req) {
    const u = String(req.username || '').trim();
    const p = String(req.password || '');
    let nick = String(req.nickname || '');
    if (u.length < 3 || u.length > 20) return err('用户名需 3-20 位字符');
    if (p.length < 6) return err('密码至少 6 位');
    if (state.users[u]) return err('用户名已存在');
    if (!nick) nick = u;
    state.users[u] = { pwd: hashPwd(p), nick, chips: 1000, lastSeen: now() };
    const token = newToken();
    state.tokens[token] = u;
    state.seq++; saveState();
    return { code: 200, body: { ok: true, token, username: u, nickname: nick, chips: 1000 } };
  }
  // 登录
  if (pathname === '/api/login' && req) {
    const u = String(req.username || '').trim();
    const p = String(req.password || '');
    if (!state.users[u]) return err('用户不存在');
    if (state.users[u].pwd !== hashPwd(p)) return err('密码错误');
    state.users[u].lastSeen = now();
    const token = newToken();
    state.tokens[token] = u;
    saveState();
    return { code: 200, body: { ok: true, token, username: u, nickname: state.users[u].nick, chips: state.users[u].chips } };
  }
  // 轮询
  if (pathname === '/api/poll') {
    const me = getMe(query.token || (req && req.token));
    if (!me) return err('未登录', 401);
    state.users[me].lastSeen = now();
    const t = now();
    const users = Object.keys(state.users).map(k => ({
      username: k, nickname: state.users[k].nick, chips: state.users[k].chips,
      online: t - state.users[k].lastSeen < 9000
    }));
    const convs = {};
    for (const key of Object.keys(state.convs)) {
      const parts = key.split('__');
      if (parts.indexOf(me) >= 0) convs[key] = state.convs[key];
    }
    const games = [];
    for (const g of Object.values(state.games)) {
      if (g.host === me || g.guest === me) games.push(buildGameView(g, me));
    }
    return {
      code: 200,
      body: {
        ok: true, seq: state.seq, now: t,
        me: { username: me, nickname: state.users[me].nick, chips: state.users[me].chips },
        users, convs, games
      }
    };
  }
  // 改昵称
  if (pathname === '/api/nickname' && req) {
    const me = getMe(req.token);
    if (!me) return err('未登录', 401);
    const nick = String(req.nickname || '').trim();
    if (nick.length < 1 || nick.length > 20) return err('昵称需 1-20 字');
    state.users[me].nick = nick;
    state.seq++; saveState();
    return { code: 200, body: { ok: true, nickname: nick } };
  }
  // 发消息
  if (pathname === '/api/messages' && req) {
    const me = getMe(req.token);
    if (!me) return err('未登录', 401);
    const peer = String(req.peer || '');
    if (!state.users[peer]) return err('用户不存在');
    let type = String(req.type || 'text');
    const content = String(req.content || '');
    if (type === 'text' && !content.trim()) return err('内容为空');
    const msg = addMsg(me, peer, type, content, String(req.gameId || ''));
    saveState();
    return { code: 200, body: { ok: true, msg } };
  }
  // 撤回
  if (pathname === '/api/messages/recall' && req) {
    const me = getMe(req.token);
    if (!me) return err('未登录', 401);
    for (const list of Object.values(state.convs)) {
      for (const m of list) {
        if (m.id === String(req.msgId) && m.sender === me) {
          if (now() - m.ts < 120000) {
            m.recalled = true; state.seq++; saveState();
            return { code: 200, body: { ok: true } };
          }
          return err('超过 2 分钟不可撤回');
        }
      }
    }
    return err('消息不存在');
  }
  // 清空聊天
  if (pathname === '/api/messages/clear' && req) {
    const me = getMe(req.token);
    if (!me) return err('未登录', 401);
    const peer = String(req.peer || '');
    delete state.convs[convKey(me, peer)];
    state.seq++; saveState();
    return { code: 200, body: { ok: true } };
  }
  // 充值
  if (pathname === '/api/chips/recharge' && req) {
    const me = getMe(req.token);
    if (!me) return err('未登录', 401);
    if (String(req.pwd || '') !== RECHARGE_PWD) return err('充值密码错误');
    let amount = parseInt(req.amount, 10);
    if (!(amount >= 1)) amount = 1000;
    state.users[me].chips = parseInt(state.users[me].chips, 10) + amount;
    state.seq++; saveState();
    return { code: 200, body: { ok: true, chips: state.users[me].chips } };
  }
  // 创建游戏
  if (pathname === '/api/game/create' && req) {
    const me = getMe(req.token);
    if (!me) return err('未登录', 401);
    const peer = String(req.peer || '');
    const type = String(req.type || '');
    if (['niuniu', 'zhajinhua', 'showhand'].indexOf(type) < 0) return err('未知游戏');
    if (!state.users[peer]) return err('用户不存在');
    let bet = parseInt(req.bet, 10);
    if (!(bet >= 10)) bet = 50;
    const id = 'g' + state.seq;
    const g = {
      id, type, host: me, guest: peer,
      status: 'waiting', bet, pot: 0, currentBet: bet, round: 0,
      turn: null, winner: null, result: '',
      lastAction: '等待对方接受邀请',
      hostCards: [], guestCards: [],
      hostLooked: false, guestLooked: false,
      hostFolded: false, guestFolded: false,
      hostOpened: false, guestOpened: false,
      hostSelection: null, guestSelection: null,
      hostResult: null, guestResult: null,
      hostSubmitted: false, guestSubmitted: false,
      deck: [], street: 0,
      hostHole: null, guestHole: null,
      hostUp: [], guestUp: [],
      hostStreet: 0, guestStreet: 0,
      hostActed: false, guestActed: false,
      ts: now()
    };
    state.games[id] = g;
    const typeName = type === 'niuniu' ? '牛牛' : type === 'showhand' ? '梭哈' : '炸金花';
    addMsg(me, peer, 'game_invite', typeName, id);
    state.seq++; saveState();
    return { code: 200, body: { ok: true, gameId: id } };
  }
  // 游戏动作
  if (pathname === '/api/game/action' && req) {
    const me = getMe(req.token);
    if (!me) return err('未登录', 401);
    const gid = String(req.gameId || '');
    const g = state.games[gid];
    if (!g) return err('游戏不存在');
    if (g.host !== me && g.guest !== me) return err('你不在这局游戏中');
    const act = String(req.act || '');
    const iAmHost = g.host === me;
    const other = iAmHost ? g.guest : g.host;

    // 接受邀请
    if (act === 'join') {
      if (g.status !== 'waiting') return ok();
      if (state.users[g.host].chips < g.bet || state.users[g.guest].chips < g.bet) {
        return err('有玩家筹码不足，无法开始');
      }
      state.users[g.host].chips -= g.bet;
      state.users[g.guest].chips -= g.bet;
      const deck = newDeck();
      if (g.type === 'niuniu') {
        g.hostCards = deck.slice(0, 5); g.guestCards = deck.slice(5, 10);
      } else if (g.type === 'showhand') {
        g.deck = deck;
        g.hostHole = deck[0]; g.guestHole = deck[1];
        g.hostUp = [deck[2]]; g.guestUp = [deck[3]];
        g.street = 1;
      } else {
        g.hostCards = deck.slice(0, 3); g.guestCards = deck.slice(3, 6);
      }
      g.pot = g.bet * 2;
      if (g.type === 'niuniu') {
        g.status = 'selecting';
        g.lastAction = '发牌完成！请选择3张牌凑牛';
      } else if (g.type === 'showhand') {
        g.status = 'playing';
        g.currentBet = 0;
        g.turn = showhandFirst(g);
        g.lastAction = '梭哈开始！底牌+第1张明牌已发，' + nickOf(g.turn) + ' 先说话';
      } else {
        g.status = 'playing';
        g.lastAction = '游戏开始！双方已下底注';
        g.turn = g.host;
      }
      state.seq++; saveState();
      return ok();
    }

    // 拒绝
    if (act === 'decline' && g.status === 'waiting') {
      if (me !== g.guest) return err('只有被邀请人可以拒绝');
      g.status = 'ended';
      g.result = '对方拒绝了游戏邀请';
      g.lastAction = g.result;
      state.seq++; saveState();
      return ok();
    }

    // 牛牛：手动选牌
    if (g.type === 'niuniu') {
      if (g.status !== 'selecting') return err('当前不可选牌');
      const mySubmitted = iAmHost ? g.hostSubmitted : g.guestSubmitted;
      if (mySubmitted) return err('你已确认过牌型');
      const myCards = iAmHost ? g.hostCards : g.guestCards;

      if (act === 'confirmspecial') {
        const sp = checkSpecial(myCards);
        if (!sp) return err('你没有特殊牌型');
        if (iAmHost) { g.hostResult = sp; g.hostSubmitted = true; } else { g.guestResult = sp; g.guestSubmitted = true; }
        g.lastAction = nickOf(me) + ' 确认牌型：' + sp.name;
        if (g.hostSubmitted && g.guestSubmitted) endNiuNiu(g);
        state.seq++; saveState();
        return ok();
      }
      if (act === 'noniu') {
        if (iAmHost) { g.hostResult = { name: '没牛', score: 0 }; g.hostSubmitted = true; }
        else { g.guestResult = { name: '没牛', score: 0 }; g.guestSubmitted = true; }
        g.lastAction = nickOf(me) + ' 确认：没牛';
        if (g.hostSubmitted && g.guestSubmitted) endNiuNiu(g);
        state.seq++; saveState();
        return ok();
      }
      if (act === 'select') {
        const selRaw = req.selIdx;
        if (!selRaw) return err('请选择3张牌');
        const sel = selRaw.map(x => parseInt(x, 10));
        if (sel.length !== 3) return err('需要选3张牌');
        if (sel.filter((v, i) => sel.indexOf(v) === i).length !== 3) return err('不能选同一张牌');
        if (sel.some(x => x < 0 || x > 4)) return err('牌索引越界');
        const result = evalManualNiu(myCards, sel);
        if (!result) return err('这3张牌之和不是10的倍数，凑不成牛！请重新选或选「没牛」');
        if (iAmHost) { g.hostSelection = sel; g.hostResult = result; g.hostSubmitted = true; }
        else { g.guestSelection = sel; g.guestResult = result; g.guestSubmitted = true; }
        g.lastAction = nickOf(me) + ' 确认牌型：' + result.name;
        if (g.hostSubmitted && g.guestSubmitted) endNiuNiu(g);
        state.seq++; saveState();
        return ok();
      }
      return err('未知动作');
    }

    // 梭哈
    if (g.type === 'showhand') {
      if (g.status !== 'playing') return err('游戏未在进行');
      const nn = nickOf(me);
      if (act === 'fold') {
        if (g.turn !== me) return err('还没轮到你操作');
        if (iAmHost) g.hostFolded = true; else g.guestFolded = true;
        g.status = 'ended';
        awardPot(g, other);
        g.result = nn + ' 弃牌，' + nickOf(other) + ' 赢得奖池 ' + g.pot + ' 筹码';
        g.lastAction = g.result;
        addMsg(g.host, g.guest, 'system', '🎴 梭哈：' + g.result, g.id);
        state.seq++; saveState();
        return ok();
      }
      if (g.turn !== me) return err('还没轮到你操作');
      const myPaid = iAmHost ? g.hostStreet : g.guestStreet;
      if (act === 'call') {
        let cost = g.currentBet - myPaid;
        if (cost < 0) cost = 0;
        if (state.users[me].chips < cost) return err('筹码不足，请点击 ＋ 补充');
        state.users[me].chips -= cost;
        g.pot += cost;
        if (iAmHost) { g.hostStreet = g.currentBet; g.hostActed = true; }
        else { g.guestStreet = g.currentBet; g.guestActed = true; }
        g.lastAction = cost === 0 ? (nn + ' 过牌') : (nn + ' 跟注 ' + cost);
        const otherActed = iAmHost ? g.guestActed : g.hostActed;
        const otherPaid = iAmHost ? g.guestStreet : g.hostStreet;
        if (otherActed && otherPaid === g.currentBet) advanceShowhand(g);
        else g.turn = other;
        state.seq++; saveState();
        return ok();
      }
      if (act === 'raise') {
        const newBet = g.currentBet === 0 ? g.bet : g.currentBet * 2;
        const cost = newBet - myPaid;
        if (state.users[me].chips < cost) return err('筹码不足，请点击 ＋ 补充');
        state.users[me].chips -= cost;
        g.pot += cost;
        g.currentBet = newBet;
        if (iAmHost) { g.hostStreet = newBet; g.hostActed = true; g.guestActed = false; }
        else { g.guestStreet = newBet; g.guestActed = true; g.hostActed = false; }
        g.turn = other;
        g.lastAction = nn + ' 加注，本轮需跟 ' + newBet + '（本次投入 ' + cost + '）';
        state.seq++; saveState();
        return ok();
      }
      return err('未知动作');
    }

    // 炸金花
    if (g.type === 'zhajinhua') {
      if (g.status !== 'playing') return err('游戏未在进行');
      const myLooked = iAmHost ? g.hostLooked : g.guestLooked;
      if (act === 'look') {
        if (iAmHost) g.hostLooked = true; else g.guestLooked = true;
        g.lastAction = nickOf(me) + ' 看了牌';
        state.seq++; saveState();
        return ok();
      }
      if (g.turn !== me) return err('还没轮到你操作');
      const nn = nickOf(me);
      if (act === 'call') {
        const cost = myLooked ? g.currentBet * 2 : g.currentBet;
        if (state.users[me].chips < cost) return err('筹码不足，请点击 ＋ 补充');
        state.users[me].chips -= cost; g.pot += cost; g.round++;
        g.turn = other;
        g.lastAction = nn + ' 跟注 ' + cost;
      } else if (act === 'raise') {
        const cost = myLooked ? g.currentBet * 4 : g.currentBet * 2;
        if (state.users[me].chips < cost) return err('筹码不足，请点击 ＋ 补充');
        state.users[me].chips -= cost; g.pot += cost;
        if (myLooked) g.currentBet *= 2;
        g.round++;
        g.turn = other;
        g.lastAction = nn + ' 加注 ' + cost + '，当前注 ' + g.currentBet;
      } else if (act === 'fold') {
        if (iAmHost) g.hostFolded = true; else g.guestFolded = true;
        g.status = 'ended';
        awardPot(g, other);
        g.result = nn + ' 弃牌，' + nickOf(other) + ' 赢得奖池 ' + g.pot + ' 筹码';
        g.lastAction = g.result;
        addMsg(g.host, g.guest, 'system', '🎮 炸金花：' + g.result, g.id);
        state.seq++; saveState();
        return ok();
      } else if (act === 'compare') {
        if (!myLooked) return err('请先看牌再比牌');
        const cost = g.currentBet * 2;
        if (state.users[me].chips < cost) return err('筹码不足，请点击 ＋ 补充');
        state.users[me].chips -= cost; g.pot += cost;
        endZjh(g, 'compare');
        state.seq++; saveState();
        return ok();
      } else {
        return err('未知动作');
      }
      if (g.round >= 12) {
        g.hostLooked = true; g.guestLooked = true;
        endZjh(g, 'autocompare');
      }
      state.seq++; saveState();
      return ok();
    }
    return err('未知动作');
  }
  return err('未知接口', 404);
}

function ok() { return { code: 200, body: { ok: true } }; }
function err(msg, code) { return { code: code || 400, body: { ok: false, error: msg } }; }

// ---------- HTTP 服务 ----------
const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const u = new URL(req.url, 'http://localhost');
  const pathname = u.pathname;
  const query = {};
  for (const [k, v] of u.searchParams) query[k] = v;

  if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
    fs.readFile(HTML_FILE, (e, data) => {
      if (e) { res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }); res.end('index.html not found'); return; }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(data);
    });
    return;
  }
  if (pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }

  if (pathname.indexOf('/api/') === 0) {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 30 * 1024 * 1024) { req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      let body = null;
      const text = Buffer.concat(chunks).toString('utf8');
      if (text) { try { body = JSON.parse(text); } catch (e) { body = null; } }
      if (body && !body.token && query.token) body.token = query.token;
      let result;
      try {
        result = handleApi(pathname, query, body);
      } catch (e) {
        console.error('API错误 ' + pathname + ': ' + e.stack);
        result = err('服务器内部错误', 500);
      }
      const json = JSON.stringify(result.body);
      res.writeHead(result.code, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(json);
    });
    req.on('error', () => { try { res.destroy(); } catch (e) {} });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not Found');
});

loadState();
server.listen(PORT, '0.0.0.0', () => {
  console.log('==============================================');
  console.log('  聊天工坊服务器（Node 版）已启动！');
  console.log('  本机访问： http://localhost:' + PORT);
  console.log('==============================================');
});
