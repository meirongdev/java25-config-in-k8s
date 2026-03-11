package dev.meirong.k8sexperiment;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class StressControllerTest {

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void memoryStress_allocatesGarbageAndReturnsStats() {
        var response = restTemplate.getForEntity("/stress/memory?mb=5", Map.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).containsKey("allocated_mb");
        assertThat(response.getBody()).containsKey("duration_ms");
    }

    @Test
    void cpuStress_runsComputationAndReturnsPrimeCount() {
        // seconds=0 让计算立即结束，避免测试变慢
        var response = restTemplate.getForEntity("/stress/cpu?seconds=0", Map.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).containsKey("primes_found");
    }

    @Test
    void health_returnsUp() {
        var response = restTemplate.getForEntity("/actuator/health", Map.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
    }
}
