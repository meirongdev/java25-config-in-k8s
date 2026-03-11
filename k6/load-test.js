import http from 'k6/http';
import { check, sleep } from 'k6';

// BASE_URL 通过环境变量注入，默认 localhost:8080
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  vus: 10,        // 10 个并发虚拟用户
  duration: '60s', // 每个场景跑 60 秒
};

export default function () {
  const rand = Math.random();

  if (rand < 0.6) {
    // 60% 请求：分配内存触发 GC（每次 30MB 的短生命周期对象）
    const res = http.get(`${BASE_URL}/stress/memory?mb=30`);
    check(res, {
      'memory stress 200': (r) => r.status === 200,
    });
  } else {
    // 40% 请求：CPU 压力（每次 1 秒计算）
    const res = http.get(`${BASE_URL}/stress/cpu?seconds=1`);
    check(res, {
      'cpu stress 200': (r) => r.status === 200,
    });
  }

  sleep(0.1);
}
