package dev.meirong.k8sexperiment;

import org.springframework.stereotype.Service;
import java.util.Arrays;

@Service
public class StressService {

    /**
     * 分配 mb 兆字节的短生命周期对象，主动触发 GC。
     * 每次 1MB 一个 chunk，填充内容防止 JIT 优化掉分配。
     */
    public long allocateGarbage(int mb) {
        long start = System.currentTimeMillis();
        for (int i = 0; i < mb; i++) {
            byte[] chunk = new byte[1024 * 1024];
            Arrays.fill(chunk, (byte) (i & 0xFF));
            // chunk 在下次循环时成为垃圾，触发 GC
        }
        return System.currentTimeMillis() - start;
    }

    /**
     * 持续计算质数，直到 seconds 秒超时。
     * 用于产生 CPU 压力。
     */
    public long computePrimes(int seconds) {
        long endTime = System.currentTimeMillis() + ((long) seconds * 1000);
        long count = 0;
        long n = 2;
        while (System.currentTimeMillis() < endTime) {
            if (isPrime(n)) count++;
            n++;
        }
        return count;
    }

    private boolean isPrime(long n) {
        if (n < 2) return false;
        for (long i = 2; i * i <= n; i++) {
            if (n % i == 0) return false;
        }
        return true;
    }
}
