package dev.meirong.k8sexperiment;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.Map;

@RestController
@RequestMapping("/stress")
public class StressController {

    private final StressService stressService;

    public StressController(StressService stressService) {
        this.stressService = stressService;
    }

    @GetMapping("/memory")
    public ResponseEntity<Map<String, Object>> stressMemory(
            @RequestParam(defaultValue = "50") int mb) {
        long durationMs = stressService.allocateGarbage(mb);
        return ResponseEntity.ok(Map.of(
                "allocated_mb", mb,
                "duration_ms", durationMs
        ));
    }

    @GetMapping("/cpu")
    public ResponseEntity<Map<String, Object>> stressCpu(
            @RequestParam(defaultValue = "2") int seconds) {
        long primesFound = stressService.computePrimes(seconds);
        return ResponseEntity.ok(Map.of(
                "duration_seconds", seconds,
                "primes_found", primesFound
        ));
    }
}
